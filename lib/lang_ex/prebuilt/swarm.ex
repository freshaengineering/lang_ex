defmodule LangEx.Prebuilt.Swarm do
  @moduledoc """
  Builds a peer-to-peer team of agents that hand control to one another.

  Every agent can transfer the conversation to any other agent. The
  currently active agent is tracked in the `:active_agent` state key and
  persisted across invocations via the graph's checkpointer, so a
  follow-up message resumes with whichever agent last held the
  conversation.

      graph =
        LangEx.Prebuilt.Swarm.create(
          agents: [
            [name: :router, model: "gpt-4o", system_prompt: "Route the user."],
            [name: :refunds, model: "gpt-4o", system_prompt: "Handle refunds."]
          ],
          default_active_agent: :router,
          checkpointer: LangEx.Checkpointer.Memory
        )

      {:ok, state} =
        LangEx.invoke(graph, %{messages: [LangEx.Message.human("I want a refund")]},
          config: [thread_id: "t-1"]
        )

  Each agent is given a handoff tool (`transfer_to_<peer>`) for every
  other agent automatically; no manual wiring is required.
  """

  alias LangEx.Graph
  alias LangEx.LLM.ChatModel
  alias LangEx.Message
  alias LangEx.Prebuilt.Handoff
  alias LangEx.Prebuilt.Member

  @active_agent_key :active_agent

  @doc """
  Builds and compiles a swarm graph.

  ## Options

  - `:agents` (required) - list of member specs (keyword lists) forwarded
    to `LangEx.Prebuilt.Member.build/1`; each must include `:name`
  - `:default_active_agent` (required) - the agent that handles the first
    turn when no active agent is set
  - `:checkpointer` - persists `:active_agent` and messages across turns
  - `:store` - long-term memory backend shared by all members
  - `:handoff_tool_prefix` - prefix for generated handoff tool names
    (default names are `"transfer_to_<peer>"`)
  """
  @spec create(keyword()) :: Graph.Compiled.t()
  def create(opts) do
    specs = Keyword.fetch!(opts, :agents)
    default = Keyword.fetch!(opts, :default_active_agent)
    store = Keyword.get(opts, :store)
    prefix = Keyword.get(opts, :handoff_tool_prefix)
    names = Enum.map(specs, &Keyword.fetch!(&1, :name))

    Graph.new(
      messages: {[], &Message.add_messages/2},
      llm_usage: {%{}, &ChatModel.merge_usage/2},
      active_agent: default
    )
    |> add_agent_nodes(specs, names, store, prefix)
    |> route_from_start(names, default)
    |> route_between_agents(names)
    |> Graph.compile(name: :swarm, checkpointer: Keyword.get(opts, :checkpointer), store: store)
  end

  defp add_agent_nodes(graph, specs, names, store, prefix) do
    Enum.reduce(specs, graph, fn spec, acc ->
      name = Keyword.fetch!(spec, :name)
      member = Member.build(member_spec(spec, names, store, prefix))
      Graph.add_node(acc, name, Member.node(member, name, :full_history))
    end)
  end

  defp member_spec(spec, names, store, prefix) do
    peers = List.delete(names, Keyword.fetch!(spec, :name))
    handoffs = Enum.map(peers, &Handoff.tool(&1, prefix: prefix))
    Keyword.merge(spec, handoff_tools: handoffs, store: store)
  end

  defp route_from_start(graph, names, default) do
    Graph.add_conditional_edges(graph, :__start__, start_router(default), name_map(names))
  end

  defp route_between_agents(graph, names) do
    mapping = Map.put(name_map(names), :__end__, :__end__)

    Enum.reduce(names, graph, fn name, acc ->
      Graph.add_conditional_edges(acc, name, agent_router(name), mapping)
    end)
  end

  defp name_map(names), do: Map.new(names, &{&1, &1})

  defp start_router(default) do
    fn state -> Map.get(state, @active_agent_key) || default end
  end

  defp agent_router(self) do
    fn state -> route_active(Map.get(state, @active_agent_key), self) end
  end

  defp route_active(active, self) when active in [nil, self], do: :__end__
  defp route_active(active, _self), do: active
end
