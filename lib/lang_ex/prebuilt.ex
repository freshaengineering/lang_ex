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
  """

  alias LangEx.ContextCompaction
  alias LangEx.Graph
  alias LangEx.LLM.ChatModel
  alias LangEx.Message

  @agent_opt_keys [
    :name,
    :system_prompt,
    :tools,
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
  `:llm_usage` (accumulating token usage via `ChatModel.merge_usage/2`).

  ## Options

  - `:model` / `:provider` - forwarded to `ChatModel.node/1` (one is required)
  - `:tools` - list of `%LangEx.Tool{}` (default `[]`; without tools the
    graph is a single LLM turn)
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
    tools = Keyword.get(agent_opts, :tools, [])

    Graph.new(
      messages: {[], &Message.add_messages/2},
      llm_usage: {%{}, &ChatModel.merge_usage/2}
    )
    |> Graph.add_node(:agent, agent_node(llm_opts, tools, agent_opts))
    |> Graph.add_edge(:__start__, :agent)
    |> add_tool_loop(tools, agent_opts)
    |> Graph.compile(
      name: Keyword.get(agent_opts, :name, :agent),
      checkpointer: Keyword.get(agent_opts, :checkpointer),
      store: Keyword.get(agent_opts, :store),
      interrupt_before: Keyword.get(agent_opts, :interrupt_before, []),
      interrupt_after: Keyword.get(agent_opts, :interrupt_after, [])
    )
  end

  defp agent_node(llm_opts, tools, agent_opts) do
    chat = ChatModel.node(llm_opts ++ [tools: tools])
    system_prompt = Keyword.get(agent_opts, :system_prompt)
    compaction = Keyword.get(agent_opts, :compaction, [])

    fn state ->
      state.messages
      |> ensure_system(system_prompt)
      |> compact(compaction)
      |> then(&chat.(%{state | messages: &1}))
    end
  end

  defp add_tool_loop(graph, [], _agent_opts), do: Graph.add_edge(graph, :agent, :__end__)

  defp add_tool_loop(graph, tools, agent_opts) do
    graph
    |> Graph.add_node(
      :tools,
      LangEx.Tool.Node.node(tools, Keyword.get(agent_opts, :tool_opts, []))
    )
    |> Graph.add_conditional_edges(:agent, &LangEx.Tool.Node.tools_condition/1, %{
      tools: :tools,
      __end__: :__end__
    })
    |> Graph.add_edge(:tools, :agent)
  end

  defp ensure_system(messages, nil), do: messages
  defp ensure_system([%Message.System{} | _] = messages, _prompt), do: messages
  defp ensure_system(messages, prompt), do: [Message.system(prompt) | messages]

  defp compact(messages, false), do: messages

  defp compact([%Message.System{} | _] = messages, compaction_opts),
    do: ContextCompaction.compact_if_needed(messages, compaction_opts)

  defp compact(messages, _compaction_opts), do: messages
end
