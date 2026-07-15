defmodule LangEx.Prebuilt.Supervisor do
  @moduledoc """
  Builds a hub-and-spoke team: a supervisor agent delegates to workers
  and workers report back to the supervisor.

  The supervisor is a tool-calling agent whose tools are handoffs to each
  worker. When it calls one it can attach a task brief; control moves to
  that worker for a turn; the worker does its work and its result is
  reported back to the supervisor as an attributed message, so the
  supervisor can tell each specialist's findings apart from its own
  reasoning. The supervisor then delegates again or answers and ends the
  run.

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
  - `:agents` (required) - list of workers. Each is either a member spec
    (keyword list forwarded to `LangEx.Prebuilt.Member.build/1`, including
    `:name`) or a `{name, compiled_graph}` pair — a pre-built agent or an
    entire nested team (any `LangEx.Graph.Compiled` on the `:messages`
    channel) used as a worker, which is how hierarchical teams are built
  - `:prompt` - supervisor system prompt
  - `:tools` - extra non-handoff tools for the supervisor (default `[]`)
  - `:supervisor_name` - supervisor node/agent name (default `:supervisor`)
  - `:output_mode` - `:full_history` (default) reports a worker's full
    textual output back to the supervisor; `:last_message` reports only its
    final message
  - `:handoff_tool_prefix` - prefix for generated handoff tool names
    (default names are `"transfer_to_<worker>"`)
  - `:parallel` - when `true`, a supervisor turn that calls several worker
    handoffs dispatches those workers concurrently (via `%LangEx.Send{}`)
    and fans their attributed results back in one step, instead of the
    default one-worker-at-a-time delegation. Each worker's task rides in
    the handoff call arguments (not a shared transcript message), so
    concurrent workers do not see one another's briefs. In-member
    interrupts are not supported for concurrently dispatched workers.
  - `:state_schema` - extra team state keys (`key: default` or
    `key: {default, reducer}`) the supervisor's own tools can read and
    update, shared without double reduction. Workers run on a scoped task
    view and report an attributed message, so custom keys are shared with
    the supervisor hub, not merged back from workers.
  - `:response_format` - a JSON-schema map; when set, after the supervisor
    produces its final answer a structured step decodes it into the
    `:structured_response` state key (via
    `LangEx.LLM.ChatModel.structured_node/1`) before the run ends
  - `:forward_message` - when `true`, the supervisor gets a
    `forward_message` tool that forwards a named worker's latest reply
    verbatim as the final answer (no paraphrasing), ending the run
  - `:interrupt_before` / `:interrupt_after` - node names (the supervisor
    or a worker) to pause at before/after that node runs (static
    breakpoints; requires a `:checkpointer`, resume with
    `%LangEx.Command{resume: value}`)
  - `:checkpointer` / `:store` - persistence and shared memory
  - other options (`:temperature`, `:api_key`, ...) are forwarded to the
    supervisor's LLM node
  """

  alias LangEx.Command
  alias LangEx.Graph
  alias LangEx.Graph.Compiled
  alias LangEx.Graph.Pregel
  alias LangEx.LLM.ChatModel
  alias LangEx.Message
  alias LangEx.Prebuilt.Handoff
  alias LangEx.Prebuilt.Member
  alias LangEx.Send
  alias LangEx.Tool

  @active_agent_key :active_agent
  @fanout_agent :__fanout__
  @forwarded_agent :__forwarded__
  @structured_node :structured_output
  @reserved_keys [
    :agents,
    :supervisor_name,
    :output_mode,
    :checkpointer,
    :prompt,
    :handoff_tool_prefix,
    :parallel,
    :state_schema,
    :response_format,
    :forward_message,
    :interrupt_before,
    :interrupt_after
  ]

  @doc "Builds and compiles a supervisor team graph."
  @spec create(keyword()) :: Compiled.t()
  def create(opts) do
    workers = Keyword.fetch!(opts, :agents)
    sup_name = Keyword.get(opts, :supervisor_name, :supervisor)
    output_mode = Keyword.get(opts, :output_mode, :full_history)
    store = Keyword.get(opts, :store)
    parallel = Keyword.get(opts, :parallel, false)
    prefix = Keyword.get(opts, :handoff_tool_prefix)
    state_schema = Keyword.get(opts, :state_schema, [])
    response_format = Keyword.get(opts, :response_format)
    finish = finish_node(response_format)
    entries = Enum.map(workers, &worker_entry(&1, store, state_schema))
    worker_names = Enum.map(entries, &elem(&1, 0))

    :ok = validate_workers!(worker_names)
    :ok = validate_supervisor_name!(sup_name, worker_names)
    :ok = validate_state_schema!(state_schema)

    handoff_tools =
      handoff_tools(worker_names, prefix, parallel) ++
        forward_tools(worker_names, Keyword.get(opts, :forward_message, false))

    ([
       messages: {[], &Message.add_messages/2},
       llm_usage: {%{}, &ChatModel.merge_usage/2},
       active_agent: sup_name
     ] ++ structured_schema(response_format) ++ state_schema)
    |> Graph.new()
    |> Graph.add_node(
      sup_name,
      supervisor_node(opts, sup_name, handoff_tools, store, state_schema)
    )
    |> add_worker_nodes(entries, sup_name, output_mode)
    |> Graph.add_edge(:__start__, sup_name)
    |> route_from_supervisor(sup_name, worker_names, handoff_tools, parallel, finish)
    |> report_to_supervisor(sup_name, worker_names)
    |> add_structured_step(response_format, opts)
    |> Graph.compile(
      name: :supervisor,
      checkpointer: Keyword.get(opts, :checkpointer),
      store: store,
      warn_unreachable: not parallel,
      interrupt_before: Keyword.get(opts, :interrupt_before, []),
      interrupt_after: Keyword.get(opts, :interrupt_after, [])
    )
  end

  # A worker is either a member spec (built into a member agent) or a
  # `{name, compiled_graph}` pair — a pre-built agent or an entire nested
  # team used as a worker, enabling hierarchical teams.
  defp worker_entry({name, %Compiled{} = compiled}, _store, _state_schema) when is_atom(name) do
    {name, compiled}
  end

  defp worker_entry(spec, store, state_schema) when is_list(spec) do
    name = Keyword.fetch!(spec, :name)
    {name, Member.build(Keyword.merge(spec, store: store, state_schema: state_schema))}
  end

  defp handoff_tools(worker_names, prefix, false) do
    Enum.map(worker_names, &Handoff.tool(&1, prefix: prefix, task_description: true))
  end

  defp handoff_tools(worker_names, prefix, true) do
    Enum.map(
      worker_names,
      &Handoff.tool(&1,
        prefix: prefix,
        task_description: true,
        active_agent_value: @fanout_agent,
        brief_message: false
      )
    )
  end

  defp forward_tools(_worker_names, false), do: []
  defp forward_tools(worker_names, true), do: [forward_message_tool(worker_names)]

  # Lets the supervisor forward a worker's latest message verbatim as the
  # final answer instead of paraphrasing it. The tool appends that message
  # as the supervisor's own reply and ends the run.
  defp forward_message_tool(worker_names) do
    %Tool{
      name: "forward_message",
      description:
        "Forward the latest message from a named agent verbatim as the final answer, " <>
          "without rewriting it.",
      parameters: %{
        type: "object",
        properties: %{
          from: %{
            type: "string",
            description: "The agent whose latest message to forward.",
            enum: Enum.map(worker_names, &Atom.to_string/1)
          }
        },
        required: ["from"]
      },
      function: fn %{"from" => from}, %{state: state, tool_call_id: id} ->
        %Command{
          update: %{
            @active_agent_key => @forwarded_agent,
            :messages => [
              Message.tool("Forwarded the #{from} agent's message.", id),
              Message.ai(forwarded_content(state.messages, from))
            ]
          }
        }
      end
    }
  end

  defp forwarded_content(messages, from) do
    prefix = "Response from the #{from} agent:\n\n"
    messages |> Enum.reverse() |> Enum.find_value("", &forwarded_text(&1, prefix))
  end

  defp forwarded_text(%Message.Human{content: content}, prefix) when is_binary(content) do
    content |> String.starts_with?(prefix) |> strip_prefix(content, prefix)
  end

  defp forwarded_text(_message, _prefix), do: nil

  defp strip_prefix(true, content, prefix), do: String.replace_prefix(content, prefix, "")
  defp strip_prefix(false, _content, _prefix), do: nil

  defp supervisor_node(opts, sup_name, handoff_tools, store, state_schema) do
    opts
    |> Keyword.drop(@reserved_keys)
    |> Keyword.merge(
      name: sup_name,
      system_prompt: Keyword.get(opts, :prompt),
      handoff_tools: handoff_tools,
      store: store,
      state_schema: state_schema
    )
    |> Member.build()
    |> Member.node(sup_name, :full_history)
  end

  defp add_worker_nodes(graph, entries, sup_name, output_mode) do
    Enum.reduce(entries, graph, fn {name, compiled}, acc ->
      Graph.add_node(acc, name, worker_node(compiled, name, sup_name, output_mode))
    end)
  end

  defp validate_state_schema!(state_schema) do
    state_schema
    |> Keyword.keys()
    |> Enum.filter(&(&1 in [:messages, :llm_usage, :active_agent]))
    |> assert_no_reserved_keys!()
  end

  defp assert_no_reserved_keys!([]), do: :ok

  defp assert_no_reserved_keys!(reserved) do
    raise ArgumentError,
          ":state_schema cannot redefine reserved team key(s): #{inspect(reserved)}"
  end

  # A worker runs on a task-focused view, then reports its output back to
  # the supervisor as an attributed user-role message. The worker runs as
  # a child execution, so its token deltas stream out and an interrupt
  # inside it pauses the whole team, resumable at the team level.
  defp worker_node(worker, name, sup_name, output_mode) do
    fn state, context ->
      view = task_view(state.messages)

      worker
      |> Pregel.run_child(%{:messages => view}, context: context)
      |> report(view, name, sup_name, output_mode)
    end
  end

  defp report({:ok, result}, view, name, sup_name, output_mode) do
    text = result.messages |> Enum.drop(length(view)) |> summarize(output_mode)

    %{
      :messages => [Message.human("Response from the #{name} agent:\n\n#{text}")],
      :llm_usage => Map.get(result, :llm_usage, %{}),
      @active_agent_key => sup_name
    }
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

  defp route_from_supervisor(graph, sup_name, worker_names, _handoff_tools, false, finish) do
    mapping = worker_names |> Map.new(&{&1, &1}) |> Map.put(:__end__, finish)
    Graph.add_conditional_edges(graph, sup_name, supervisor_router(sup_name), mapping)
  end

  # Parallel routing has no fixed mapping: the router inspects the
  # supervisor's most recent tool calls and emits one `%Send{}` per
  # requested worker, so the workers listed are only known at runtime.
  defp route_from_supervisor(graph, sup_name, worker_names, handoff_tools, true, finish) do
    Graph.add_conditional_edges(
      graph,
      sup_name,
      fanout_router(worker_by_tool(handoff_tools, worker_names), finish)
    )
  end

  defp structured_schema(nil), do: []
  defp structured_schema(_schema), do: [structured_response: nil]

  defp finish_node(nil), do: :__end__
  defp finish_node(_schema), do: @structured_node

  defp add_structured_step(graph, nil, _opts), do: graph

  defp add_structured_step(graph, schema, opts) do
    llm_opts = Keyword.drop(opts, @reserved_keys ++ [:tools])

    graph
    |> Graph.add_node(
      @structured_node,
      ChatModel.structured_node(llm_opts ++ [schema: schema, into: :structured_response])
    )
    |> Graph.add_edge(@structured_node, :__end__)
  end

  defp worker_by_tool(handoff_tools, worker_names) do
    handoff_tools
    |> Enum.zip(worker_names)
    |> Map.new(fn {tool, worker} -> {tool.name, worker} end)
  end

  defp fanout_router(worker_by_tool, finish) do
    fn state ->
      state.messages |> handoff_requests(worker_by_tool) |> fanout_or_end(state, finish)
    end
  end

  defp fanout_or_end([], _state, finish), do: finish
  defp fanout_or_end(requests, state, _finish), do: Enum.map(requests, &worker_send(&1, state))

  defp handoff_requests(messages, worker_by_tool) do
    messages
    |> last_ai_tool_calls()
    |> Enum.flat_map(&worker_request(&1, worker_by_tool))
  end

  defp last_ai_tool_calls(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&match?(%Message.AI{}, &1))
    |> ai_tool_calls()
  end

  defp ai_tool_calls(%Message.AI{tool_calls: calls}), do: calls
  defp ai_tool_calls(_message), do: []

  defp worker_request(%Message.ToolCall{name: name, args: args}, worker_by_tool) do
    worker_by_tool
    |> Map.fetch(name)
    |> request_for(args)
  end

  defp request_for({:ok, worker}, args), do: [{worker, Map.get(args, "task_description")}]
  defp request_for(:error, _args), do: []

  defp worker_send({worker, task}, state) do
    %Send{
      node: worker,
      state: %{
        :messages => worker_messages(state.messages, worker, task),
        @active_agent_key => worker
      }
    }
  end

  defp worker_messages(messages, worker, task) when is_binary(task) and task != "" do
    task_view(messages) ++ [Message.human("Task for the #{worker} agent: #{task}")]
  end

  defp worker_messages(messages, _worker, _task), do: task_view(messages)

  defp report_to_supervisor(graph, sup_name, worker_names) do
    Enum.reduce(worker_names, graph, fn name, acc -> Graph.add_edge(acc, name, sup_name) end)
  end

  defp supervisor_router(sup_name) do
    fn state -> route_supervisor(Map.get(state, @active_agent_key), sup_name) end
  end

  defp route_supervisor(active, sup_name) when active in [nil, sup_name, @forwarded_agent],
    do: :__end__

  defp route_supervisor(active, _sup_name), do: active

  defp validate_workers!([]) do
    raise ArgumentError, "Supervisor.create/1 requires at least one worker in :agents"
  end

  defp validate_workers!(names) do
    names
    |> duplicates()
    |> assert_no_duplicates!()
  end

  defp assert_no_duplicates!([]), do: :ok

  defp assert_no_duplicates!(dups) do
    raise ArgumentError, "duplicate agent name(s) in :agents: #{inspect(dups)}"
  end

  defp validate_supervisor_name!(sup_name, worker_names) do
    sup_name
    |> Kernel.in(worker_names)
    |> assert_distinct_supervisor!(sup_name)
  end

  defp assert_distinct_supervisor!(false, _sup_name), do: :ok

  defp assert_distinct_supervisor!(true, sup_name) do
    raise ArgumentError, ":supervisor_name #{inspect(sup_name)} collides with a worker name"
  end

  defp duplicates(names) do
    names
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, _count} -> name end)
  end
end
