defmodule LangEx.Prebuilt.Supervisor do
  @moduledoc """
  Builds a hub-and-spoke team: a supervisor agent delegates to workers
  and workers return control to the supervisor.

  The supervisor is a tool-calling agent whose tools are handoffs to each
  worker. When it calls one, control moves to that worker for a turn;
  when the worker finishes, control returns to the supervisor, which
  either delegates again or answers and ends the run.

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

  ## Options

  - `:model` / `:provider` (required) - the supervisor's LLM
  - `:agents` (required) - list of worker member specs (keyword lists)
    forwarded to `LangEx.Prebuilt.Member.build/1`; each must include `:name`
  - `:prompt` - supervisor system prompt
  - `:tools` - extra non-handoff tools for the supervisor (default `[]`)
  - `:supervisor_name` - supervisor node/agent name (default `:supervisor`)
  - `:output_mode` - `:full_history` (default) contributes every worker
    message back to the conversation; `:last_message` contributes only
    the worker's final message
  - `:handoff_tool_prefix` - prefix for generated handoff tool names
    (default names are `"transfer_to_<worker>"`)
  - `:add_handoff_back_messages` - when `true`, the continuation prompt
    added each time control returns to the supervisor explicitly names the
    return (default `false`). A user-role continuation prompt is always
    added on return so the supervisor's next turn is valid for providers
    that reject a trailing assistant message.
  - `:checkpointer` / `:store` - persistence and shared memory
  - other options (`:temperature`, `:api_key`, ...) are forwarded to the
    supervisor's LLM node
  """

  alias LangEx.Graph
  alias LangEx.LLM.ChatModel
  alias LangEx.Message
  alias LangEx.Prebuilt.Handoff
  alias LangEx.Prebuilt.Member

  @active_agent_key :active_agent
  @return_node :return_to_supervisor
  @reserved_keys [
    :agents,
    :supervisor_name,
    :output_mode,
    :checkpointer,
    :prompt,
    :handoff_tool_prefix,
    :add_handoff_back_messages
  ]

  @doc "Builds and compiles a supervisor team graph."
  @spec create(keyword()) :: Graph.Compiled.t()
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
    |> add_worker_nodes(workers, output_mode, store)
    |> Graph.add_node(@return_node, return_node(sup_name, opts))
    |> Graph.add_edge(:__start__, sup_name)
    |> route_from_supervisor(sup_name, worker_names)
    |> return_to_supervisor(sup_name, worker_names)
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

  defp add_worker_nodes(graph, workers, output_mode, store) do
    Enum.reduce(workers, graph, fn spec, acc ->
      name = Keyword.fetch!(spec, :name)
      member = Member.build(Keyword.merge(spec, store: store))
      Graph.add_node(acc, name, Member.node(member, name, output_mode))
    end)
  end

  defp return_node(sup_name, opts) do
    opts
    |> Keyword.get(:add_handoff_back_messages, false)
    |> reset_active(sup_name)
  end

  # A user-role continuation prompt is always appended when control
  # returns to the supervisor: the worker's contribution ends on an
  # assistant message, and providers such as Anthropic reject an LLM call
  # whose conversation ends on an assistant turn. `add_handoff_back_messages`
  # makes that prompt explicitly name the return.
  defp reset_active(false, sup_name) do
    fn _state ->
      %{
        @active_agent_key => sup_name,
        :messages => [Message.human(continue_prompt())]
      }
    end
  end

  defp reset_active(true, sup_name) do
    fn _state ->
      %{
        @active_agent_key => sup_name,
        :messages => [Message.human("Control returned to #{sup_name}. #{continue_prompt()}")]
      }
    end
  end

  defp continue_prompt,
    do:
      "Review the responses above, then delegate again if needed or give the user a final answer."

  defp route_from_supervisor(graph, sup_name, worker_names) do
    mapping = worker_names |> Map.new(&{&1, &1}) |> Map.put(:__end__, :__end__)
    Graph.add_conditional_edges(graph, sup_name, supervisor_router(sup_name), mapping)
  end

  defp return_to_supervisor(graph, sup_name, worker_names) do
    worker_names
    |> Enum.reduce(graph, fn name, acc -> Graph.add_edge(acc, name, @return_node) end)
    |> Graph.add_edge(@return_node, sup_name)
  end

  defp supervisor_router(sup_name) do
    fn state -> route_supervisor(Map.get(state, @active_agent_key), sup_name) end
  end

  defp route_supervisor(active, sup_name) when active in [nil, sup_name], do: :__end__
  defp route_supervisor(active, _sup_name), do: active
end
