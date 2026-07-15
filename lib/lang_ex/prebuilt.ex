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
    :pre_model_hook,
    :post_model_hook,
    :response_format,
    :tool_opts
  ]
  @structured_node :structured_output

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
  - `:pre_model_hook` - `(messages -> messages)` applied to the message
    list just before the LLM call (e.g. trimming or extra instructions)
  - `:post_model_hook` - `(update -> update)` applied to the node result
    map after the LLM call (e.g. guardrails)
  - `:response_format` - a JSON-schema map; when set, a final structured
    step decodes the answer into the `:structured_response` state key (via
    `LangEx.LLM.ChatModel.structured_node/1`) before the graph ends
  - `:tool_opts` - options for `LangEx.Tool.Node.node/2`
    (`:handle_tool_errors`, `:max_concurrency`, `:timeout`, ...)
  - All other options (`:resilient`, `:temperature`, `:api_key`, ...)
    are forwarded to `ChatModel.node/1`
  """
  @spec agent(keyword()) :: Graph.Compiled.t()
  def agent(opts) do
    {agent_opts, llm_opts} = Keyword.split(opts, @agent_opt_keys)
    tools = Keyword.get(agent_opts, :tools, [])
    response_format = Keyword.get(agent_opts, :response_format)

    ([messages: {[], &Message.add_messages/2}, llm_usage: {%{}, &ChatModel.merge_usage/2}] ++
       structured_schema(response_format))
    |> Graph.new()
    |> Graph.add_node(:agent, agent_node(llm_opts, tools, agent_opts))
    |> Graph.add_edge(:__start__, :agent)
    |> add_tool_loop(tools, agent_opts, finish_node(response_format))
    |> add_structured_step(response_format, llm_opts)
    |> Graph.compile(
      name: Keyword.get(agent_opts, :name, :agent),
      checkpointer: Keyword.get(agent_opts, :checkpointer),
      store: Keyword.get(agent_opts, :store),
      interrupt_before: Keyword.get(agent_opts, :interrupt_before, []),
      interrupt_after: Keyword.get(agent_opts, :interrupt_after, [])
    )
  end

  defp structured_schema(nil), do: []
  defp structured_schema(_schema), do: [structured_response: nil]

  defp finish_node(nil), do: :__end__
  defp finish_node(_schema), do: @structured_node

  defp add_structured_step(graph, nil, _llm_opts), do: graph

  defp add_structured_step(graph, schema, llm_opts) do
    graph
    |> Graph.add_node(
      @structured_node,
      ChatModel.structured_node(llm_opts ++ [schema: schema, into: :structured_response])
    )
    |> Graph.add_edge(@structured_node, :__end__)
  end

  defp agent_node(llm_opts, tools, agent_opts) do
    chat = ChatModel.node(llm_opts ++ [tools: tools])
    system_prompt = Keyword.get(agent_opts, :system_prompt)
    compaction = Keyword.get(agent_opts, :compaction, [])
    pre_hook = Keyword.get(agent_opts, :pre_model_hook)
    post_hook = Keyword.get(agent_opts, :post_model_hook)

    fn state ->
      state.messages
      |> ensure_system(system_prompt)
      |> compact(compaction)
      |> apply_hook(pre_hook)
      |> then(&chat.(%{state | messages: &1}))
      |> apply_hook(post_hook)
    end
  end

  defp apply_hook(value, nil), do: value
  defp apply_hook(value, hook) when is_function(hook, 1), do: hook.(value)

  defp add_tool_loop(graph, [], _agent_opts, finish), do: Graph.add_edge(graph, :agent, finish)

  defp add_tool_loop(graph, tools, agent_opts, finish) do
    graph
    |> Graph.add_node(
      :tools,
      LangEx.Tool.Node.node(tools, Keyword.get(agent_opts, :tool_opts, []))
    )
    |> Graph.add_conditional_edges(:agent, &LangEx.Tool.Node.tools_condition/1, %{
      tools: :tools,
      __end__: finish
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
