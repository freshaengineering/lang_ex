defmodule LangEx.Middleware do
  @moduledoc """
  Composable hooks that wrap the model call inside `LangEx.Prebuilt.agent/1`.

  A middleware is a value — a `%LangEx.Middleware{}` carrying optional hook
  functions — so behaviours like summarization, context editing, planning,
  tool pre-selection, and completion gating compose without each one being
  hardcoded into the agent. The agent runs every turn through the stack:

      before_model (first → last)
        → wrap_model_call (first middleware outermost)
          → the LLM call
        → after_model (last → first)

  `after_model` runs in reverse so the stack unwinds symmetrically: the
  middleware that saw the state last on the way in sees the result first on
  the way out.

  ## Hooks

  - `:before_model` — `(state -> update)` run before the LLM call. Its
    update is applied to the working state (so the model sees it) and
    persisted. Return `:messages` instructions (including
    `LangEx.Message.remove_all/0` / `LangEx.Message.remove/1`) to rewrite
    history, not just append.
  - `:after_model` — `(state -> update)` run after the LLM call. Set
    `:__agent_jump__` to `:model` (loop again), `:tools`, or `:__end__` in
    the update to override the agent's routing — e.g. a completion gate that
    bounces an inadequate answer back for another pass.
  - `:wrap_model_call` — `(request, next -> update)` wraps the LLM call. The
    `request` is `%{messages: [...], tools: [...], state: map()}`; call
    `next.(request)` (optionally with narrowed `:tools`) to run the model.

  ## Contributions

  - `:tools` — extra `%LangEx.Tool{}` the middleware adds to the agent.
  - `:state_schema` — schema fragment (`key: default` / `key: {default,
    reducer}`) merged into the agent's graph state.

  Usage-bearing hooks (a summariser, a critic) should return their token
  usage under `:llm_usage`; the runner sums it with the turn's model usage.
  """

  alias LangEx.LLM.ChatModel
  alias LangEx.Message
  alias LangEx.Tool

  @jump_key :__agent_jump__

  defstruct name: nil,
            before_model: nil,
            after_model: nil,
            wrap_model_call: nil,
            tools: [],
            state_schema: []

  @type hook :: (map() -> map())
  @type request :: %{messages: [Message.t()], tools: [Tool.t()], state: map()}
  @type wrapper :: (request(), (request() -> map()) -> map())

  @type t :: %__MODULE__{
          name: atom() | nil,
          before_model: hook() | nil,
          after_model: hook() | nil,
          wrap_model_call: wrapper() | nil,
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

  `model_fn` is `(messages, tools -> update)` — the raw LLM call, returning a
  `%{messages_key => [ai], :llm_usage => usage}` update. `tools` is the full
  tool list offered to the model (a `wrap_model_call` hook may narrow it).
  Returns the merged, persistable update for the agent node.
  """
  @spec run_turn(map(), (list(), [Tool.t()] -> map()), [Tool.t()], [t()], atom()) :: map()
  def run_turn(state, model_fn, tools, middlewares, messages_key) do
    base = fn request -> model_fn.(request.messages, request.tools) end
    chain = compose(middlewares, base)

    {state, acc} = fold(:before_model, middlewares, state, new_acc(), messages_key)
    request = %{messages: Map.fetch!(state, messages_key), tools: tools, state: state}
    model_update = chain.(request)

    state = apply_local(state, model_update, messages_key)
    acc = accumulate(acc, model_update, messages_key)

    {_state, acc} = fold(:after_model, Enum.reverse(middlewares), state, acc, messages_key)
    finalize(acc, messages_key)
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
