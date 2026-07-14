defmodule LangEx.Prebuilt.Supervisor do
  @moduledoc """
  Builds a hub-and-spoke team: a supervisor agent delegates to workers
  and workers report back to the supervisor.

  The supervisor is a tool-calling agent whose tools are handoffs to each
  worker. When it calls one, control moves to that worker for a turn;
  the worker does its work and its result is reported back to the
  supervisor as an attributed message, so the supervisor can tell each
  specialist's findings apart from its own reasoning. The supervisor then
  delegates again or answers and ends the run.

      graph =
        LangEx.Prebuilt.Supervisor.create(
          model: "gpt-4o",
          prompt: "You manage a research and a math agent. Delegate.",
          agents: [
            [name: :research, model: "gpt-4o", tools: [search_tool]],
            [name: :math, model: "gpt-4o", tools: [calc_tool]]
          ],
          checkpointer: LangEx.Checkpointer.Memory
        )

  ## How workers see the conversation

  Each worker runs on a task-focused view of the conversation — the user
  request, prior specialist responses, and the supervisor's plain replies
  — with handoff plumbing (transfer tool calls and their acknowledgements)
  stripped out, so a worker is not confused by routing it did not perform.
  A worker's output is reported back as a user-role message attributed to
  that worker (`"Response from the <name> agent: ..."`). Attribution both
  keeps specialist findings distinguishable and leaves the conversation on
  a user turn, which providers such as Anthropic require.

  ## Options

  - `:model` / `:provider` (required) - the supervisor's LLM
  - `:agents` (required) - list of worker member specs (keyword lists)
    forwarded to `LangEx.Prebuilt.Member.build/1`; each must include `:name`
  - `:prompt` - supervisor system prompt
  - `:tools` - extra non-handoff tools for the supervisor (default `[]`)
  - `:supervisor_name` - supervisor node/agent name (default `:supervisor`)
  - `:output_mode` - `:full_history` (default) reports a worker's full
    textual output back to the supervisor; `:last_message` reports only its
    final message
  - `:handoff_tool_prefix` - prefix for generated handoff tool names
    (default names are `"transfer_to_<worker>"`)
  - `:checkpointer` / `:store` - persistence and shared memory
  - other options (`:temperature`, `:api_key`, ...) are forwarded to the
    supervisor's LLM node
  """

  alias LangEx.Graph
  alias LangEx.Graph.Compiled
  alias LangEx.LLM.ChatModel
  alias LangEx.Message
  alias LangEx.Prebuilt.Handoff
  alias LangEx.Prebuilt.Member

  @active_agent_key :active_agent
  @reserved_keys [
    :agents,
    :supervisor_name,
    :output_mode,
    :checkpointer,
    :prompt,
    :handoff_tool_prefix
  ]

  @doc "Builds and compiles a supervisor team graph."
  @spec create(keyword()) :: Compiled.t()
  def create(opts) do
    workers = Keyword.fetch!(opts, :agents)
    sup_name = Keyword.get(opts, :supervisor_name, :supervisor)
    output_mode = Keyword.get(opts, :output_mode, :full_history)
    store = Keyword.get(opts, :store)
    worker_names = Enum.map(workers, &Keyword.fetch!(&1, :name))

    Graph.new(
      messages: {[], &Message.add_messages/2},
      llm_usage: {%{}, &ChatModel.merge_usage/2},
      active_agent: sup_name
    )
    |> Graph.add_node(sup_name, supervisor_node(opts, sup_name, worker_names, store))
    |> add_worker_nodes(workers, sup_name, output_mode, store)
    |> Graph.add_edge(:__start__, sup_name)
    |> route_from_supervisor(sup_name, worker_names)
    |> report_to_supervisor(sup_name, worker_names)
    |> Graph.compile(
      name: :supervisor,
      checkpointer: Keyword.get(opts, :checkpointer),
      store: store
    )
  end

  defp supervisor_node(opts, sup_name, worker_names, store) do
    prefix = Keyword.get(opts, :handoff_tool_prefix)

    opts
    |> Keyword.drop(@reserved_keys)
    |> Keyword.merge(
      name: sup_name,
      system_prompt: Keyword.get(opts, :prompt),
      handoff_tools: Enum.map(worker_names, &Handoff.tool(&1, prefix: prefix)),
      store: store
    )
    |> Member.build()
    |> Member.node(sup_name, :full_history)
  end

  defp add_worker_nodes(graph, workers, sup_name, output_mode, store) do
    Enum.reduce(workers, graph, fn spec, acc ->
      name = Keyword.fetch!(spec, :name)
      member = Member.build(Keyword.merge(spec, store: store))
      Graph.add_node(acc, name, worker_node(member, name, sup_name, output_mode))
    end)
  end

  # A worker runs on a task-focused view, then reports its output back to
  # the supervisor as an attributed user-role message.
  defp worker_node(member, name, sup_name, output_mode) do
    fn state, context ->
      view = task_view(state.messages)

      member
      |> Compiled.invoke(%{:messages => view, @active_agent_key => name}, context: context)
      |> report(view, name, sup_name, output_mode)
    end
  end

  defp report({:ok, result}, view, name, sup_name, output_mode) do
    text = result.messages |> Enum.drop(length(view)) |> summarize(output_mode)

    %{
      :messages => [Message.human("Response from the #{name} agent:\n\n#{text}")],
      @active_agent_key => sup_name
    }
  end

  # A worker runs as a nested execution, so an interrupt or error inside it
  # cannot resume across the team boundary — surface it as an error.
  defp report(outcome, _view, name, _sup_name, _output_mode) do
    raise "worker #{inspect(name)} did not complete normally: #{inspect(outcome)}"
  end

  # Workers see the user request, prior specialist responses, and the
  # supervisor's plain replies — but not handoff plumbing (transfer tool
  # calls and their acknowledgements) or a seeded system prompt, which
  # would shadow the worker's own role prompt.
  defp task_view(messages), do: Enum.filter(messages, &task_relevant?/1)

  defp task_relevant?(%Message.Human{}), do: true

  defp task_relevant?(%Message.AI{tool_calls: [], content: content})
       when is_binary(content) and content != "",
       do: true

  defp task_relevant?(_message), do: false

  defp summarize(delta, :last_message), do: delta |> ai_texts() |> List.last() |> to_string()
  defp summarize(delta, _full_history), do: delta |> ai_texts() |> Enum.join("\n\n")

  defp ai_texts(messages) do
    for %Message.AI{content: content} <- messages,
        is_binary(content) and content != "",
        do: content
  end

  defp route_from_supervisor(graph, sup_name, worker_names) do
    mapping = worker_names |> Map.new(&{&1, &1}) |> Map.put(:__end__, :__end__)
    Graph.add_conditional_edges(graph, sup_name, supervisor_router(sup_name), mapping)
  end

  defp report_to_supervisor(graph, sup_name, worker_names) do
    Enum.reduce(worker_names, graph, fn name, acc -> Graph.add_edge(acc, name, sup_name) end)
  end

  defp supervisor_router(sup_name) do
    fn state -> route_supervisor(Map.get(state, @active_agent_key), sup_name) end
  end

  defp route_supervisor(active, sup_name) when active in [nil, sup_name], do: :__end__
  defp route_supervisor(active, _sup_name), do: active
end
