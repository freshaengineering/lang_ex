defmodule LangEx.Middleware do
  @moduledoc """
  Composable hooks that wrap the model call inside `LangEx.Prebuilt.agent/1`.

  A middleware is a value — a `%LangEx.Middleware{}` carrying optional hook
  functions — so behaviours like summarization, context editing, planning,
  tool pre-selection, and completion gating compose without each one being
  hardcoded into the agent. A run passes through the stack like this:

      before_agent (first → last, once per run)
        │
        ├─ every turn:
        │    before_model (first → last)
        │      → wrap_model_call (first middleware outermost)
        │        → the LLM call
        │      → after_model (last → first)
        │    before_tools (first → last, when tools were requested)
        │      → wrap_tool_call (first middleware outermost, per call)
        │
      after_agent (last → first, once per run)

  Hooks that run on the way out (`after_model`, `after_agent`) run in
  reverse so the stack unwinds symmetrically: the middleware that saw the
  state last on the way in sees the result first on the way out.

  ## Turn hooks

  - `:before_model` — `(state -> update)` run before the LLM call. Its
    update is applied to the working state (so the model sees it) and
    persisted. Return `:messages` instructions (including
    `LangEx.Message.remove_all/0` / `LangEx.Message.remove/1`) to rewrite
    history, not just append.
  - `:after_model` — `(state -> update)` run after the LLM call. Set
    `:__agent_jump__` to `:model` (loop again), `:tools`, or `:__end__` in
    the update to override the agent's routing — e.g. a completion gate that
    bounces an inadequate answer back for another pass.
  - `:wrap_model_call` — `(request, next -> update)` wraps the LLM call.
    The `request` is a `%LangEx.Middleware.ModelRequest{}`; derive a
    changed one with `ModelRequest.override/2` (model, prompt, tools, tool
    choice, provider options) and call `next.(request)` to run it.

  ## Run hooks

  - `:before_agent` — `(state -> update)` run once before the first model
    call of a run, for setup that must not repeat every turn: loading a
    user profile from the store, seeding a plan, stamping a run ID.
  - `:after_agent` — `(state -> update)` run once when the agent is about
    to finish, for teardown: persisting what was learned, emitting a
    summary, clearing scratch state.

  Both run once per `invoke`, not per turn. On a resume they do not re-run,
  because their earlier update is already in the checkpointed state.

  ## Tool hooks

  - `:before_tools` — `(state -> update)` run after the model asks for
    tools and before they execute. It runs as its own graph node, so
    unlike `after_model` it may call `LangEx.Interrupt.interrupt/1`: a
    resume re-runs only this hook, not the model call whose tool requests
    are being reviewed. Set `:__agent_jump__` in the update to steer
    routing (`:model` to hand control back to the model, `:__end__` to
    stop). Answer a call in advance by appending its
    `%LangEx.Message.Tool{}` — the tools node then skips it and runs the
    rest of the batch.
  - `:wrap_tool_call` — `(request, execute -> result)` wraps each tool
    call. The `request` is a `%LangEx.Tool.Node.ToolCallRequest{}`; return
    `execute.(request)` to run the tool, or return a `%LangEx.Message.Tool{}`
    / `%LangEx.Command{}` to answer without running it. Wrappers from
    several middleware compose, first-declared outermost. Tool calls run in
    their own tasks, so a wrapper cannot interrupt — use `:before_tools`
    for anything needing human input.

  ## Contributions

  - `:tools` — extra `%LangEx.Tool{}` the middleware adds to the agent.
  - `:state_schema` — schema fragment (`key: default` / `key: {default,
    reducer}`) merged into the agent's graph state.

  Usage-bearing hooks (a summariser, a critic) should return their token
  usage under `:llm_usage`; the runner sums it with the turn's model usage.

  ## Contributed-key semantics

  The runner accumulates `:messages` (concatenating instructions, so
  `remove_all/0`/`remove/1` work) and `:llm_usage` (summing) across all
  hooks. Any other contributed key uses last-write-wins for the turn — a
  custom reducer declared in `:state_schema` is still applied once by the
  graph engine when the turn's update is committed, but is **not** re-applied
  between hooks within a turn, so two hooks writing the same custom-reducer
  key in one turn keep only the last write. Keep middleware state keys
  last-write-wins (as the built-ins do) to avoid surprise.
  """

  alias LangEx.LLM.ChatModel
  alias LangEx.Message
  alias LangEx.Middleware.ModelRequest
  alias LangEx.Tool

  @jump_key :__agent_jump__

  defstruct name: nil,
            before_agent: nil,
            before_model: nil,
            after_model: nil,
            before_tools: nil,
            after_agent: nil,
            wrap_model_call: nil,
            wrap_tool_call: nil,
            tools: [],
            state_schema: []

  @type hook :: (map() -> map())
  @type request :: ModelRequest.t()
  @type wrapper :: (request(), (request() -> map()) -> map())
  @type tool_wrapper :: (term(), (term() -> term()) -> term())

  @type t :: %__MODULE__{
          name: atom() | nil,
          before_agent: hook() | nil,
          before_model: hook() | nil,
          after_model: hook() | nil,
          before_tools: hook() | nil,
          after_agent: hook() | nil,
          wrap_model_call: wrapper() | nil,
          wrap_tool_call: tool_wrapper() | nil,
          tools: [Tool.t()],
          state_schema: keyword()
        }

  @doc "Builds a middleware from a keyword list of hooks and contributions."
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc "The reserved state key an `after_model` hook sets to steer routing."
  @spec jump_key() :: atom()
  def jump_key, do: @jump_key

  @doc "All tools contributed across a middleware stack, in order."
  @spec tools([t()]) :: [Tool.t()]
  def tools(middlewares), do: Enum.flat_map(middlewares, & &1.tools)

  @doc "The merged schema fragment contributed across a middleware stack."
  @spec state_schema([t()]) :: keyword()
  def state_schema(middlewares), do: Enum.flat_map(middlewares, & &1.state_schema)

  @doc """
  Runs one model turn through the middleware stack.

  `model_fn` is `(%ModelRequest{} -> update)` — the raw LLM call, returning a
  `%{messages_key => [ai], :llm_usage => usage}` update. It reads the model,
  prompt, tools and provider options off the request, so a `wrap_model_call`
  hook can redirect the call. `tools` is the full tool list offered to the
  model. Returns the merged, persistable update for the agent node.
  """
  @spec run_turn(map(), (ModelRequest.t() -> map()), [Tool.t()], [t()], atom()) :: map()
  def run_turn(state, model_fn, tools, middlewares, messages_key) do
    chain = compose(middlewares, model_fn)

    {state, acc} = fold(:before_model, middlewares, state, new_acc(), messages_key)

    model_update =
      chain.(
        ModelRequest.new(
          messages: Map.fetch!(state, messages_key),
          tools: tools,
          state: state
        )
      )

    state = apply_local(state, model_update, messages_key)
    acc = accumulate(acc, model_update, messages_key)

    {_state, acc} = fold(:after_model, Enum.reverse(middlewares), state, acc, messages_key)
    finalize(acc, messages_key)
  end

  @doc """
  Runs a run-scoped hook (`:before_agent` / `:after_agent`) across the stack.

  Returns the merged update to commit. `:after_agent` is run with the stack
  reversed by the caller so the stack unwinds symmetrically.
  """
  @spec run_hooks(map(), [t()], atom(), atom()) :: map()
  def run_hooks(state, middlewares, kind, messages_key) do
    {_state, acc} = fold(kind, middlewares, state, new_acc(), messages_key)
    finalize(acc, messages_key)
  end

  @doc "True when any middleware in the stack declares `kind`."
  @spec declares?([t()], atom()) :: boolean()
  def declares?(middlewares, kind), do: Enum.any?(middlewares, &Map.fetch!(&1, kind))

  @doc """
  The composed `wrap_tool_call` interceptor for a stack, or `nil` when none.

  First-declared middleware is outermost, matching `wrap_model_call`.
  """
  @spec tool_wrapper([t()]) :: tool_wrapper() | nil
  def tool_wrapper(middlewares) do
    middlewares
    |> Enum.filter(& &1.wrap_tool_call)
    |> nest_tool_wrappers()
  end

  defp nest_tool_wrappers([]), do: nil

  defp nest_tool_wrappers(middlewares) do
    fn request, execute ->
      middlewares
      |> Enum.reverse()
      |> Enum.reduce(execute, fn mw, next ->
        fn req -> mw.wrap_tool_call.(req, next) end
      end)
      |> then(& &1.(request))
    end
  end

  defp compose(middlewares, base) do
    middlewares
    |> Enum.filter(& &1.wrap_model_call)
    |> Enum.reverse()
    |> Enum.reduce(base, fn mw, next -> fn request -> mw.wrap_model_call.(request, next) end end)
  end

  defp fold(kind, middlewares, state, acc, messages_key) do
    Enum.reduce(middlewares, {state, acc}, fn mw, {st, ac} ->
      mw |> Map.fetch!(kind) |> run_hook(st, ac, messages_key)
    end)
  end

  defp run_hook(nil, state, acc, _messages_key), do: {state, acc}

  defp run_hook(hook, state, acc, messages_key) when is_function(hook, 1) do
    update = hook.(state) || %{}
    {apply_local(state, update, messages_key), accumulate(acc, update, messages_key)}
  end

  defp apply_local(state, update, messages_key) do
    Enum.reduce(update, state, fn {key, value}, st -> put_local(key, value, st, messages_key) end)
  end

  defp put_local(key, value, state, messages_key) when key == messages_key do
    state
    |> Map.get(messages_key, [])
    |> Message.add_messages(value)
    |> then(&Map.put(state, messages_key, &1))
  end

  defp put_local(:llm_usage, value, state, _messages_key) do
    state
    |> Map.get(:llm_usage)
    |> ChatModel.merge_usage(value)
    |> then(&Map.put(state, :llm_usage, &1))
  end

  defp put_local(key, value, state, _messages_key), do: Map.put(state, key, value)

  defp new_acc, do: %{messages: [], usage: %{}, other: %{}}

  defp accumulate(acc, update, messages_key) do
    Enum.reduce(update, acc, fn {key, value}, ac -> acc_key(key, value, ac, messages_key) end)
  end

  defp acc_key(key, value, acc, messages_key) when key == messages_key,
    do: %{acc | messages: acc.messages ++ List.wrap(value)}

  defp acc_key(:llm_usage, value, acc, _messages_key),
    do: %{acc | usage: ChatModel.merge_usage(acc.usage, value)}

  defp acc_key(key, value, acc, _messages_key),
    do: %{acc | other: Map.put(acc.other, key, value)}

  defp finalize(acc, messages_key) do
    acc.other
    |> Map.put(messages_key, acc.messages)
    |> put_usage(acc.usage)
  end

  defp put_usage(update, usage) when map_size(usage) == 0, do: update
  defp put_usage(update, usage), do: Map.put(update, :llm_usage, usage)
end
