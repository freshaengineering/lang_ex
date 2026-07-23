defmodule LangEx.Prebuilt do
  @moduledoc """
  Ready-made graph constructors for common agent shapes.

  `agent/1` builds the canonical tool-calling loop — an LLM node, a
  tool-execution node, and the routing between them — with usage
  accounting and context compaction wired in:

      graph =
        LangEx.Prebuilt.agent(
          model: "claude-opus-4-20250514",
          system_prompt: "You are a helpful DevOps assistant.",
          tools: [health_tool, logs_tool],
          checkpointer: LangEx.Checkpointer.Postgres
        )

      {:ok, result} =
        LangEx.invoke(graph, %{messages: [Message.human("Is api-gateway healthy?")]},
          config: [thread_id: "ops-1", repo: MyApp.Repo]
        )

  ## Middleware

  Pass `:middleware` (a list of `%LangEx.Middleware{}`) to layer extra
  behaviour around the model call — summarisation, context editing,
  planning, tool pre-selection, completion gating — without changing the
  agent's shape. Built-in middleware lives under `LangEx.Middleware.*`:

      LangEx.Prebuilt.agent(
        model: "claude-opus-4-20250514",
        tools: tools,
        middleware: [
          LangEx.Middleware.Summarization.new(model: "claude-haiku-4-5-20251001"),
          LangEx.Middleware.TodoList.new(),
          LangEx.Middleware.Rubric.new(rubric: "Cites logs and names a root cause.")
        ]
      )
  """

  alias LangEx.ContextCompaction
  alias LangEx.Graph
  alias LangEx.LLM.ChatModel
  alias LangEx.Message
  alias LangEx.Middleware
  alias LangEx.Prebuilt.Reflect
  alias LangEx.Tool

  require Logger

  @agent_opt_keys [
    :name,
    :system_prompt,
    :tools,
    :middleware,
    :checkpointer,
    :store,
    :compaction,
    :interrupt_before,
    :interrupt_after,
    :tool_opts
  ]

  @doc """
  Builds and compiles a tool-calling agent graph.

  The graph state has `:messages` (with `Message.add_messages/2`) and
  `:llm_usage` (accumulating token usage via `ChatModel.merge_usage/2`),
  plus any keys contributed by `:middleware`.

  ## Options

  - `:model` / `:provider` - forwarded to `ChatModel.node/1` (one is required)
  - `:tools` - list of `%LangEx.Tool{}`, or a `fn state -> [%LangEx.Tool{}] end`
    resolved from state each turn (for tools discovered at runtime and kept
    out of checkpointed state). Default `[]`; without tools the graph is a
    single LLM turn
  - `:middleware` - list of `%LangEx.Middleware{}` wrapping the model call
    (default `[]`); their tools and state schema are merged in automatically
  - `:system_prompt` - prepended as a system message when the
    conversation does not already start with one
  - `:name` - graph name for telemetry (default `:agent`)
  - `:checkpointer` - enables persistence, interrupts, and resume
  - `:store` - long-term memory backend (see `LangEx.Store`)
  - `:compaction` - context compaction options passed to
    `LangEx.ContextCompaction.compact_if_needed/2`; `false` disables
    (default `[]` — compaction with defaults). This trims only the *model's
    view* each turn; the full history stays in state. For persisted
    compaction use `LangEx.Middleware.Summarization` (and pass
    `compaction: false`).
  - `:interrupt_before` / `:interrupt_after` - static breakpoints,
    forwarded to `Graph.compile/2` (nodes: `:agent`, `:tools`)
  - `:tool_opts` - options for `LangEx.Tool.Node.node/2`
    (`:handle_tool_errors`, `:max_concurrency`, `:timeout`, ...)
  - All other options (`:resilient`, `:temperature`, `:api_key`, ...)
    are forwarded to `ChatModel.node/1`
  """
  @spec agent(keyword()) :: Graph.Compiled.t()
  def agent(opts) do
    {agent_opts, llm_opts} = Keyword.split(opts, @agent_opt_keys)
    middlewares = Keyword.get(agent_opts, :middleware, [])
    tools_spec = Keyword.get(agent_opts, :tools, [])
    static_tools = Middleware.tools(middlewares)
    resolver = tool_resolver(tools_spec, static_tools)

    middlewares
    |> agent_schema()
    |> Graph.new()
    |> Graph.add_node(:agent, agent_node(llm_opts, resolver, agent_opts, middlewares))
    |> Graph.add_edge(:__start__, :agent)
    |> add_tool_loop(resolver, has_tools?(tools_spec, static_tools), agent_opts, middlewares)
    |> Graph.compile(
      name: Keyword.get(agent_opts, :name, :agent),
      checkpointer: Keyword.get(agent_opts, :checkpointer),
      store: Keyword.get(agent_opts, :store),
      interrupt_before: Keyword.get(agent_opts, :interrupt_before, []),
      interrupt_after: Keyword.get(agent_opts, :interrupt_after, [])
    )
  end

  # Tools may be a static list or a `fn state -> [tool] end` resolved per turn
  # (for agents whose tools are discovered at runtime). Middleware-contributed
  # tools are always appended.
  defp tool_resolver(tools_spec, static_tools) when is_function(tools_spec, 1),
    do: fn state -> tools_spec.(state) ++ static_tools end

  defp tool_resolver(tools_spec, static_tools) when is_list(tools_spec),
    do: fn _state -> tools_spec ++ static_tools end

  defp has_tools?(tools_spec, _static_tools) when is_function(tools_spec, 1), do: true
  defp has_tools?(tools_spec, static_tools), do: tools_spec != [] or static_tools != []

  @doc """
  Builds a generate → critique → revise reflection graph.

  Delegates to `LangEx.Prebuilt.Reflect.create/1`; see that module for
  options and state shape.
  """
  @spec reflect(keyword()) :: Graph.Compiled.t()
  def reflect(opts), do: Reflect.create(opts)

  # Middleware fragments are merged first so the core :messages / :llm_usage
  # reducers always win a key collision and can't be silently clobbered.
  defp agent_schema(middlewares) do
    middlewares
    |> Middleware.state_schema()
    |> Keyword.merge(
      messages: {[], &Message.add_messages/2},
      llm_usage: {%{}, &ChatModel.merge_usage/2}
    )
    |> add_jump_key(middlewares)
  end

  defp add_jump_key(schema, []), do: schema
  defp add_jump_key(schema, _middlewares), do: Keyword.put(schema, Middleware.jump_key(), nil)

  defp agent_node(llm_opts, resolver, agent_opts, middlewares) do
    system_prompt = Keyword.get(agent_opts, :system_prompt)
    compaction = Keyword.get(agent_opts, :compaction, [])
    model_fn = model_fn(llm_opts)

    fn state ->
      state.messages
      |> ensure_system(system_prompt)
      |> compact(compaction)
      |> then(&%{state | messages: &1})
      |> then(&(&1 |> Middleware.run_turn(model_fn, resolver.(&1), middlewares, :messages)))
      |> reset_jump(middlewares)
    end
  end

  defp model_fn(llm_opts) do
    fn messages, call_tools, state ->
      call = ChatModel.node(Keyword.put(llm_opts, :tools, call_tools))
      call.(Map.merge(state, %{messages: messages, llm_usage: Map.get(state, :llm_usage, %{})}))
    end
  end

  defp reset_jump(update, []), do: update
  defp reset_jump(update, _middlewares), do: Map.put_new(update, Middleware.jump_key(), nil)

  defp add_tool_loop(graph, resolver, has_tools?, agent_opts, middlewares) do
    graph
    |> add_tools_node(resolver, has_tools?, agent_opts)
    |> route_agent(has_tools?, middlewares)
  end

  defp add_tools_node(graph, _resolver, false, _agent_opts), do: graph

  defp add_tools_node(graph, resolver, true, agent_opts) do
    tool_opts = Keyword.get(agent_opts, :tool_opts, [])

    graph
    |> Graph.add_node(:tools, tools_node(resolver, tool_opts))
    |> Graph.add_edge(:tools, :agent)
  end

  # Resolve tools from state per execution so runtime-discovered tools work;
  # rebuilding the Tool.Node closure each call is cheap.
  defp tools_node(resolver, tool_opts) do
    fn state -> state |> resolver.() |> Tool.Node.node(tool_opts) |> then(& &1.(state)) end
  end

  defp route_agent(graph, false, []), do: Graph.add_edge(graph, :agent, :__end__)

  defp route_agent(graph, true, []) do
    Graph.add_conditional_edges(graph, :agent, &Tool.Node.tools_condition/1, %{
      tools: :tools,
      __end__: :__end__
    })
  end

  defp route_agent(graph, false, _middlewares) do
    Graph.add_conditional_edges(graph, :agent, &agent_router(&1, false), %{
      model: :agent,
      __end__: :__end__
    })
  end

  defp route_agent(graph, true, _middlewares) do
    Graph.add_conditional_edges(graph, :agent, &agent_router(&1, true), %{
      model: :agent,
      tools: :tools,
      __end__: :__end__
    })
  end

  defp agent_router(state, has_tools?) do
    state
    |> Map.get(Middleware.jump_key())
    |> resolve_jump(state, has_tools?)
  end

  defp resolve_jump(:model, _state, _has_tools?), do: :model
  defp resolve_jump(:__end__, _state, _has_tools?), do: :__end__
  defp resolve_jump(:tools, _state, true), do: :tools

  # A :tools jump is meaningless without a tools node; end the turn rather than
  # route to a target that does not exist.
  defp resolve_jump(:tools, _state, false) do
    Logger.warning(
      "Prebuilt.agent: an after_model hook requested a :tools jump but the agent " <>
        "has no tools — ending the turn instead"
    )

    :__end__
  end

  defp resolve_jump(nil, state, has_tools?) do
    state
    |> Tool.Node.tools_condition()
    |> normalize_condition(has_tools?)
  end

  defp normalize_condition(:tools, false), do: :__end__
  defp normalize_condition(condition, _has_tools?), do: condition

  defp ensure_system(messages, nil), do: messages
  defp ensure_system([%Message.System{} | _] = messages, _prompt), do: messages
  defp ensure_system(messages, prompt), do: [Message.system(prompt) | messages]

  defp compact(messages, false), do: messages

  defp compact([%Message.System{} | _] = messages, compaction_opts),
    do: ContextCompaction.compact_if_needed(messages, compaction_opts)

  defp compact(messages, _compaction_opts), do: messages
end
