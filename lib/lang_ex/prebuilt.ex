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
  - `:tools` - list of `%LangEx.Tool{}` (default `[]`; without tools the
    graph is a single LLM turn)
  - `:middleware` - list of `%LangEx.Middleware{}` wrapping the model call
    (default `[]`); their tools and state schema are merged in automatically
  - `:system_prompt` - prepended as a system message when the
    conversation does not already start with one
  - `:name` - graph name for telemetry (default `:agent`)
  - `:checkpointer` - enables persistence, interrupts, and resume
  - `:store` - long-term memory backend (see `LangEx.Store`)
  - `:compaction` - context compaction options passed to
    `LangEx.ContextCompaction.compact_if_needed/2`; `false` disables
    (default `[]` — compaction with defaults)
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
    tools = Keyword.get(agent_opts, :tools, []) ++ Middleware.tools(middlewares)

    middlewares
    |> agent_schema()
    |> Graph.new()
    |> Graph.add_node(:agent, agent_node(llm_opts, tools, agent_opts, middlewares))
    |> Graph.add_edge(:__start__, :agent)
    |> add_tool_loop(tools, agent_opts, middlewares)
    |> Graph.compile(
      name: Keyword.get(agent_opts, :name, :agent),
      checkpointer: Keyword.get(agent_opts, :checkpointer),
      store: Keyword.get(agent_opts, :store),
      interrupt_before: Keyword.get(agent_opts, :interrupt_before, []),
      interrupt_after: Keyword.get(agent_opts, :interrupt_after, [])
    )
  end

  @doc """
  Builds a generate → critique → revise reflection graph.

  Delegates to `LangEx.Prebuilt.Reflect.create/1`; see that module for
  options and state shape.
  """
  @spec reflect(keyword()) :: Graph.Compiled.t()
  def reflect(opts), do: Reflect.create(opts)

  defp agent_schema(middlewares) do
    [
      messages: {[], &Message.add_messages/2},
      llm_usage: {%{}, &ChatModel.merge_usage/2}
    ]
    |> Keyword.merge(Middleware.state_schema(middlewares))
    |> add_jump_key(middlewares)
  end

  defp add_jump_key(schema, []), do: schema
  defp add_jump_key(schema, _middlewares), do: Keyword.put(schema, Middleware.jump_key(), nil)

  defp agent_node(llm_opts, tools, agent_opts, middlewares) do
    system_prompt = Keyword.get(agent_opts, :system_prompt)
    compaction = Keyword.get(agent_opts, :compaction, [])
    model_fn = model_fn(llm_opts)

    fn state ->
      state.messages
      |> ensure_system(system_prompt)
      |> compact(compaction)
      |> then(&%{state | messages: &1})
      |> Middleware.run_turn(model_fn, tools, middlewares, :messages)
      |> reset_jump(middlewares)
    end
  end

  defp model_fn(llm_opts) do
    fn messages, call_tools ->
      call = ChatModel.node(Keyword.put(llm_opts, :tools, call_tools))
      call.(%{messages: messages, llm_usage: %{}})
    end
  end

  defp reset_jump(update, []), do: update
  defp reset_jump(update, _middlewares), do: Map.put_new(update, Middleware.jump_key(), nil)

  defp add_tool_loop(graph, tools, agent_opts, middlewares) do
    graph
    |> add_tools_node(tools, agent_opts)
    |> route_agent(tools, middlewares)
  end

  defp add_tools_node(graph, [], _agent_opts), do: graph

  defp add_tools_node(graph, tools, agent_opts) do
    graph
    |> Graph.add_node(:tools, Tool.Node.node(tools, Keyword.get(agent_opts, :tool_opts, [])))
    |> Graph.add_edge(:tools, :agent)
  end

  defp route_agent(graph, [], []), do: Graph.add_edge(graph, :agent, :__end__)

  defp route_agent(graph, _tools, []) do
    Graph.add_conditional_edges(graph, :agent, &Tool.Node.tools_condition/1, %{
      tools: :tools,
      __end__: :__end__
    })
  end

  defp route_agent(graph, [], _middlewares) do
    Graph.add_conditional_edges(graph, :agent, &agent_router/1, %{
      model: :agent,
      __end__: :__end__
    })
  end

  defp route_agent(graph, _tools, _middlewares) do
    Graph.add_conditional_edges(graph, :agent, &agent_router/1, %{
      model: :agent,
      tools: :tools,
      __end__: :__end__
    })
  end

  defp agent_router(state) do
    state
    |> Map.get(Middleware.jump_key())
    |> resolve_jump(state)
  end

  defp resolve_jump(:model, _state), do: :model
  defp resolve_jump(:tools, _state), do: :tools
  defp resolve_jump(:__end__, _state), do: :__end__
  defp resolve_jump(nil, state), do: Tool.Node.tools_condition(state)

  defp ensure_system(messages, nil), do: messages
  defp ensure_system([%Message.System{} | _] = messages, _prompt), do: messages
  defp ensure_system(messages, prompt), do: [Message.system(prompt) | messages]

  defp compact(messages, false), do: messages

  defp compact([%Message.System{} | _] = messages, compaction_opts),
    do: ContextCompaction.compact_if_needed(messages, compaction_opts)

  defp compact(messages, _compaction_opts), do: messages
end
