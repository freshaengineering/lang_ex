defmodule LangEx.Prebuilt.Member do
  @moduledoc """
  Builds a routable team-member agent for `LangEx.Prebuilt.Swarm` and
  `LangEx.Prebuilt.Supervisor`.

  A member is an ordinary tool-calling agent (LLM node plus tool node)
  compiled as its own graph, with one extra behaviour: it tracks an
  `:active_agent` state key. While `:active_agent` names the member
  itself the tool loop continues; once a handoff tool points it at a
  different agent the member ends its turn so the enclosing team can
  route control onward.

  `build/1` returns the compiled member graph; `node/3` wraps it as a
  parent-graph node that runs one turn and contributes only the messages
  it produced (so a shared conversation is not duplicated on every hop).
  The team's runtime context is forwarded into each member turn, and each
  turn's token usage is contributed back under `:llm_usage`.

  A member runs its turn as a nested execution, so a `LangEx.Interrupt`
  raised inside a member is not resumable across the team boundary —
  `node/3` surfaces it as an error instead. Keep human-in-the-loop pauses
  at the team level.
  """

  alias LangEx.ContextCompaction
  alias LangEx.Graph
  alias LangEx.LLM.ChatModel
  alias LangEx.Message

  @active_agent_key :active_agent
  @member_opt_keys [
    :name,
    :tools,
    :handoff_tools,
    :system_prompt,
    :compaction,
    :tool_opts,
    :store,
    :pre_model_hook,
    :post_model_hook
  ]

  @typedoc "How much of a member's turn is contributed back to the team."
  @type output_mode :: :full_history | :last_message

  @doc "The state key a team uses to track which agent holds the conversation."
  @spec active_agent_key() :: atom()
  def active_agent_key, do: @active_agent_key

  @doc """
  Builds and compiles a member agent.

  ## Options

  - `:name` (required) - the member's own name; also its `:active_agent`
    identity
  - `:tools` - the member's own `%LangEx.Tool{}` list (default `[]`)
  - `:handoff_tools` - handoff `%LangEx.Tool{}` list appended to `:tools`
  - `:system_prompt` - a string, or a 1-arity function `(state -> string)`
    for a dynamic prompt; prepended when the conversation has no system
    message
  - `:compaction` - forwarded to
    `LangEx.ContextCompaction.compact_if_needed/2`; `false` disables
  - `:tool_opts` - forwarded to `LangEx.Tool.Node.node/2`
  - `:store` - long-term memory backend
  - `:pre_model_hook` - `(messages -> messages)` applied to the message
    list just before the LLM call (e.g. trimming or extra instructions)
  - `:post_model_hook` - `(update -> update)` applied to the node result
    map after the LLM call (e.g. guardrails)
  - all other options (`:model`/`:provider`, `:temperature`, ...) are
    forwarded to `LangEx.LLM.ChatModel.node/1`
  """
  @spec build(keyword()) :: Graph.Compiled.t()
  def build(opts) do
    {member_opts, llm_opts} = Keyword.split(opts, @member_opt_keys)
    name = Keyword.fetch!(member_opts, :name)
    tools = Keyword.get(member_opts, :tools, []) ++ Keyword.get(member_opts, :handoff_tools, [])

    Graph.new(
      messages: {[], &Message.add_messages/2},
      llm_usage: {%{}, &ChatModel.merge_usage/2},
      active_agent: name
    )
    |> Graph.add_node(:agent, agent_node(llm_opts, tools, member_opts))
    |> Graph.add_edge(:__start__, :agent)
    |> add_tool_loop(tools, name, member_opts)
    |> Graph.compile(name: name, store: Keyword.get(member_opts, :store))
  end

  @doc """
  Wraps a compiled member as a parent-graph node.

  The node runs one member turn seeded with the shared conversation and
  the member's own name as the active agent, then returns just the
  messages produced this turn (per `output_mode`), the resulting
  `:active_agent`, and the turn's `:llm_usage`. The enclosing team's
  runtime context is forwarded into the member turn.
  """
  @spec node(Graph.Compiled.t(), atom(), output_mode()) :: (map(), term() -> map())
  def node(%Graph.Compiled{} = member, name, output_mode) do
    fn state, context ->
      member
      |> Graph.Compiled.invoke(%{:messages => state.messages, @active_agent_key => name},
        context: context
      )
      |> contribute(state, name, output_mode)
    end
  end

  @doc """
  Routing function for a member's tool node: keep looping while this
  member is active, otherwise end the turn so the team can re-route.
  """
  @spec tool_router(atom()) :: (map() -> :agent | :__end__)
  def tool_router(name) do
    fn state -> route_after_tools(Map.get(state, @active_agent_key), name) end
  end

  defp route_after_tools(active, name) when active in [nil, name], do: :agent
  defp route_after_tools(_active, _name), do: :__end__

  defp contribute({:ok, result}, state, _name, output_mode) do
    result.messages
    |> Enum.drop(length(state.messages))
    |> then(
      &%{
        :messages => select_output(&1, output_mode),
        :llm_usage => result.llm_usage,
        @active_agent_key => result.active_agent
      }
    )
  end

  defp contribute({:interrupt, _payload, _result}, _state, name, _output_mode) do
    raise "member agent #{inspect(name)} interrupted; interrupts inside team members are not supported"
  end

  defp contribute({:error, reason}, _state, name, _output_mode) do
    raise "member agent #{inspect(name)} failed: #{inspect(reason)}"
  end

  defp select_output(delta, :last_message), do: delta |> List.last() |> List.wrap()
  defp select_output(delta, _full_history), do: delta

  defp agent_node(llm_opts, tools, member_opts) do
    chat = ChatModel.node(llm_opts ++ [tools: tools])
    prompt = Keyword.get(member_opts, :system_prompt)
    compaction = Keyword.get(member_opts, :compaction, [])
    pre_hook = Keyword.get(member_opts, :pre_model_hook)
    post_hook = Keyword.get(member_opts, :post_model_hook)

    fn state ->
      state.messages
      |> ensure_system(resolve_prompt(prompt, state))
      |> compact(compaction)
      |> apply_hook(pre_hook)
      |> then(&chat.(%{state | messages: &1}))
      |> apply_hook(post_hook)
    end
  end

  defp apply_hook(value, nil), do: value
  defp apply_hook(value, hook) when is_function(hook, 1), do: hook.(value)

  defp resolve_prompt(prompt, state) when is_function(prompt, 1), do: prompt.(state)
  defp resolve_prompt(prompt, _state), do: prompt

  defp add_tool_loop(graph, [], _name, _member_opts), do: Graph.add_edge(graph, :agent, :__end__)

  defp add_tool_loop(graph, tools, name, member_opts) do
    graph
    |> Graph.add_node(
      :tools,
      LangEx.Tool.Node.node(tools, Keyword.get(member_opts, :tool_opts, []))
    )
    |> Graph.add_conditional_edges(:agent, &LangEx.Tool.Node.tools_condition/1, %{
      tools: :tools,
      __end__: :__end__
    })
    |> Graph.add_conditional_edges(:tools, tool_router(name), %{agent: :agent, __end__: :__end__})
  end

  defp ensure_system(messages, nil), do: messages
  defp ensure_system([%Message.System{} | _] = messages, _prompt), do: messages
  defp ensure_system(messages, prompt), do: [Message.system(prompt) | messages]

  defp compact(messages, false), do: messages

  defp compact([%Message.System{} | _] = messages, compaction_opts),
    do: ContextCompaction.compact_if_needed(messages, compaction_opts)

  defp compact(messages, _compaction_opts), do: messages
end
