defmodule LangEx.Graph.Pregel do
  @moduledoc """
  Super-step execution engine inspired by Google's Pregel.

  Processes the graph in discrete super-steps: resolve which nodes to
  run next, execute them, apply state updates via reducers, then repeat
  until reaching the END node or exhausting the recursion limit.

  Supports checkpointing, interrupts (dynamic and static breakpoints),
  streaming events, runtime context, Send fan-out, and managed values
  (remaining_steps).

  ## Interrupt model

  Every `LangEx.Interrupt.interrupt/1` call gets a stable ID derived from
  the node name and the call order within the node (`"node:0"`, `"node:1"`).
  Resume values are keyed by interrupt ID, so a node can interrupt multiple
  times across resume cycles, and several nodes interrupting in the same
  parallel super-step each keep their own pending entry. Completed sibling
  results in a parallel super-step are merged into state before pausing,
  and their resolved next targets are recorded in the checkpoint — nothing
  is lost when one branch interrupts.

  ## Error model

  Node exceptions (after the node's retry policy, if any, is exhausted)
  surface as `{:error, %LangEx.NodeError{}}` rather than raising out of
  the run. Programmer errors — routing to an undefined node, a missing
  conditional mapping — still raise.
  """

  alias LangEx.Checkpoint
  alias LangEx.Command
  alias LangEx.Graph.Compiled
  alias LangEx.Graph.NodeCache
  alias LangEx.Graph.RetryPolicy
  alias LangEx.Graph.State
  alias LangEx.NodeError
  alias LangEx.NodeTimeoutError
  alias LangEx.Send
  alias LangEx.Telemetry.Runs

  @type interrupt :: %{id: String.t(), value: term(), node: atom()}
  @type entry :: atom() | Send.t()

  @type run_opts :: %{
          optional(:start_nodes) => [entry()] | nil,
          optional(:parent_id) => String.t() | nil,
          optional(:bypass_breakpoints) => boolean(),
          optional(:resume_values) => %{String.t() => term()},
          optional(:raw_interrupts) => boolean(),
          optional(:max_concurrency) => pos_integer() | nil,
          optional(:node_timeout) => timeout() | nil,
          optional(:store) => {module(), keyword()} | nil,
          optional(:deferred_backlog) => [entry()],
          optional(:completed_next) => [entry()],
          optional(:durability) => :sync | :async | :exit,
          recursion_limit: pos_integer(),
          checkpointer: module() | nil,
          config: keyword(),
          context: term(),
          resume: %{nodes: [entry()], values: %{String.t() => term()}} | nil,
          step: non_neg_integer(),
          emit_to: pid() | nil
        }

  @doc "Runs the compiled graph from the start node through to completion."
  @spec run(Compiled.t(), map(), run_opts() | pos_integer()) ::
          {:ok, map()} | {:interrupt, term(), map()} | {:error, term()}
  def run(graph, state, limit) when is_integer(limit) do
    run(graph, state, %{
      recursion_limit: limit,
      checkpointer: nil,
      config: [],
      context: nil,
      resume: nil,
      step: 0,
      emit_to: nil
    })
  end

  def run(%Compiled{} = graph, state, %{} = opts) do
    metadata = graph_invoke_metadata(graph, opts)

    Runs.span([:lang_ex, :graph, :invoke], metadata, fn ->
      result = run_graph(graph, state, opts)
      {result, Map.put(metadata, :result, result_tag(result))}
    end)
  end

  defp run_graph(graph, state, %{resume: %{nodes: nodes}} = opts) when is_list(nodes) do
    step(nodes, graph, state, opts)
  end

  defp run_graph(graph, state, opts) do
    opts
    |> Map.get(:start_nodes)
    |> initial_targets(graph, state)
    |> step(graph, state, opts)
  end

  defp initial_targets(nil, graph, state), do: resolve_targets(graph, :__start__, state)
  defp initial_targets(start_nodes, _graph, _state), do: start_nodes

  defp step(nodes, graph, state, opts) do
    nodes
    |> Enum.reject(&(&1 == :__end__))
    |> run_active(graph, state, opts)
  end

  defp run_active([], graph, state, opts), do: finalize_run(graph, state, opts)

  defp run_active(nodes, _graph, _state, %{recursion_limit: limit, step: count})
       when count >= limit do
    {:error, {:recursion_limit, count, nodes}}
  end

  defp run_active(active, graph, state, opts) do
    :ok = validate_active!(graph, active)

    active
    |> Enum.split_with(&deferred?(graph, &1))
    |> run_ready(graph, state, opts)
  end

  defp validate_active!(graph, active) do
    active
    |> Enum.map(&entry_name/1)
    |> Enum.reject(&Map.has_key?(graph.nodes, &1))
    |> assert_known_targets!(graph)
  end

  defp assert_known_targets!([], _graph), do: :ok

  defp assert_known_targets!(unknown, graph) do
    raise ArgumentError,
          "cannot execute undefined node(s) #{inspect(Enum.uniq(unknown))} — " <>
            "known nodes: #{inspect(Enum.sort(Map.keys(graph.nodes)))}. " <>
            "Check Command goto and Send targets."
  end

  defp deferred?(graph, entry) do
    graph.node_opts
    |> Map.get(entry_name(entry), [])
    |> Keyword.get(:defer, false)
  end

  # Deferred nodes wait until no other node is active — a fan-in barrier.
  defp run_ready({deferred, []}, graph, state, opts),
    do: run_super_step(deferred, graph, state, opts)

  defp run_ready({deferred, ready}, graph, state, opts),
    do: run_super_step(ready, graph, state, Map.put(opts, :deferred_backlog, deferred))

  defp run_super_step([], graph, state, opts), do: finalize_run(graph, state, opts)

  defp run_super_step(active, graph, state, opts) do
    active
    |> breakpoint_hits(graph.interrupt_before, opts)
    |> pause_before_or_execute(active, graph, state, opts)
  end

  defp breakpoint_hits(_active, [], _opts), do: []

  defp breakpoint_hits(active, breakpoint_nodes, opts) do
    opts
    |> Map.get(:bypass_breakpoints, false)
    |> matching_breakpoints(active, breakpoint_nodes)
  end

  defp matching_breakpoints(true, _active, _breakpoint_nodes), do: []

  defp matching_breakpoints(false, active, breakpoint_nodes),
    do: Enum.filter(active, &(entry_name(&1) in breakpoint_nodes))

  defp pause_before_or_execute([], active, graph, state, opts),
    do: execute_super_step(active, graph, state, opts)

  defp pause_before_or_execute(hits, active, _graph, state, opts) do
    interrupts =
      Enum.map(hits, fn entry ->
        name = entry_name(entry)

        %{
          id: "before:#{name}",
          value: {:interrupt_before, name},
          node: name,
          entry: entry,
          static: true
        }
      end)

    save_interrupts(
      state,
      active ++ Map.get(opts, :deferred_backlog, []),
      interrupts,
      Map.get(opts, :completed_next, []),
      opts
    )
  end

  defp execute_super_step(active, graph, state, opts) do
    emit(opts, {:step_start, opts.step, active})
    metadata = %{step: opts.step, active_nodes: active}

    Runs.span([:lang_ex, :graph, :step], metadata, fn ->
      result =
        state
        |> inject_managed(opts)
        |> then(&execute_nodes(graph, &1, active, opts))
        |> handle_super_step_result(graph, active, state, opts)

      {result, metadata}
    end)
  end

  defp handle_super_step_result({:failed, reason}, _graph, active, state, opts) do
    save_failure_checkpoint(state, active ++ Map.get(opts, :deferred_backlog, []), opts)
    {:error, reason}
  end

  defp handle_super_step_result(
         {new_state, cmds, [_ | _] = interrupts},
         graph,
         active,
         _state,
         opts
       ) do
    clean = strip_managed(new_state, graph)
    pending = interrupts |> Enum.map(&interrupt_entry/1) |> dedup_targets()

    save_interrupts(
      clean,
      pending,
      interrupts,
      completed_targets(graph, clean, active, interrupts, cmds, opts),
      opts
    )
  end

  defp handle_super_step_result({new_state, command_targets, []}, graph, active, _state, opts) do
    clean = strip_managed(new_state, graph)
    emit(opts, {:step_end, opts.step, clean})

    next =
      graph
      |> resolve_next_nodes(clean, active, command_targets)
      |> Kernel.++(Map.get(opts, :deferred_backlog, []))
      |> Kernel.++(Map.get(opts, :completed_next, []))
      |> dedup_targets()

    active
    |> breakpoint_hits(graph.interrupt_after, opts)
    |> pause_after_or_continue(
      next,
      graph,
      clean,
      opts |> Map.delete(:deferred_backlog) |> Map.delete(:completed_next)
    )
  end

  # Targets of siblings that finished in a super-step where another
  # branch interrupted. They are persisted with the interrupt checkpoint
  # so the resumed run still visits them — resuming re-executes only the
  # interrupted entries.
  defp completed_targets(graph, state, active, interrupts, cmds, opts) do
    carried = Map.get(opts, :completed_next, []) ++ Map.get(opts, :deferred_backlog, [])

    (active -- Enum.map(interrupts, &interrupt_entry/1))
    |> resolve_completed(graph, state, cmds)
    |> Kernel.++(carried)
    |> dedup_targets()
  end

  defp resolve_completed([], _graph, _state, _cmds), do: []

  defp resolve_completed(completed, graph, state, cmds),
    do: resolve_next_nodes(graph, state, completed, cmds)

  defp interrupt_entry(%{entry: entry}), do: entry
  defp interrupt_entry(%{node: node}), do: node

  defp pause_after_or_continue([], next, graph, state, opts) do
    checkpoint_id = save_checkpoint(opts, state, next)
    continue(next, graph, state, with_parent(opts, checkpoint_id))
  end

  defp pause_after_or_continue(hits, next, _graph, state, opts) do
    interrupts =
      Enum.map(hits, fn entry ->
        name = entry_name(entry)

        %{
          id: "after:#{name}",
          value: {:interrupt_after, name},
          node: name,
          entry: entry,
          static: true
        }
      end)

    save_interrupts(state, next, interrupts, [], opts)
  end

  defp with_parent(opts, nil), do: opts
  defp with_parent(opts, checkpoint_id), do: Map.put(opts, :parent_id, checkpoint_id)

  defp continue(next, graph, state, opts) do
    step(next, graph, state, %{
      Map.put(opts, :bypass_breakpoints, false)
      | resume: nil,
        step: opts.step + 1
    })
  end

  defp finalize_run(graph, state, opts) do
    :ok = save_final_checkpoint(Map.get(opts, :durability, :sync), graph, state, opts)
    {:ok, state}
  end

  # Under :exit durability nothing was persisted along the way, so the
  # completed run gets one final checkpoint — get_state/2 stays truthful.
  defp save_final_checkpoint(:exit, _graph, state, %{checkpointer: cp, config: config} = opts)
       when not is_nil(cp) do
    config
    |> Keyword.get(:thread_id)
    |> persist_checkpoint(cp, config, :sync,
      state: state,
      next_nodes: [:__end__],
      step: opts.step,
      parent_id: Map.get(opts, :parent_id),
      metadata: %{}
    )

    :ok
  end

  defp save_final_checkpoint(_durability, _graph, _state, _opts), do: :ok

  # Under :exit durability a failed run also persists its position, so a
  # follow-up invoke with empty input can re-run the failed super-step.
  defp save_failure_checkpoint(state, active, %{checkpointer: cp, config: config} = opts)
       when not is_nil(cp) do
    opts
    |> Map.get(:durability, :sync)
    |> persist_failure(state, active, cp, config, opts)
  end

  defp save_failure_checkpoint(_state, _active, _opts), do: :ok

  defp persist_failure(:exit, state, active, cp, config, opts) do
    config
    |> Keyword.get(:thread_id)
    |> persist_checkpoint(cp, config, :sync,
      state: state,
      next_nodes: active,
      step: opts.step,
      parent_id: Map.get(opts, :parent_id),
      metadata: %{}
    )

    :ok
  end

  defp persist_failure(_durability, _state, _active, _cp, _config, _opts), do: :ok

  defp execute_nodes(graph, state, [entry], opts) do
    graph
    |> execute_single_node(state, entry, opts)
    |> normalize_single_result(state)
  end

  defp execute_nodes(graph, state, entries, opts) do
    parent_run_id = Runs.current_run_id()

    LangEx.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      entries,
      &run_entry_task(graph, &1, state, opts, parent_run_id),
      max_concurrency: max_concurrency(opts),
      timeout: :infinity,
      ordered: true
    )
    |> Enum.zip(entries)
    |> Enum.reduce({state, [], []}, &reduce_task_result(&1, &2, graph.reducers))
  end

  defp max_concurrency(opts), do: Map.get(opts, :max_concurrency) || System.schedulers_online()
  defp node_timeout(opts), do: Map.get(opts, :node_timeout) || :infinity

  # An interrupted entry pauses with the shared state, not the node's
  # input — for a Send entry the input is the payload, which must not
  # replace the graph state in the checkpoint.
  defp normalize_single_result({:interrupted, interrupt, _int_state}, shared_state),
    do: {shared_state, [], [interrupt]}

  defp normalize_single_result({:graph_error, reason}, _shared_state), do: {:failed, reason}
  defp normalize_single_result({new_state, cmds}, _shared_state), do: {new_state, cmds, []}

  defp entry_name(%Send{node: node}), do: node
  defp entry_name(node) when is_atom(node), do: node

  defp entry_input(%Send{state: payload}, _shared_state), do: payload
  defp entry_input(node, shared_state) when is_atom(node), do: shared_state

  defp run_entry_task(graph, entry, state, opts, parent_run_id) do
    Runs.inherit_run_id(parent_run_id)
    name = entry_name(entry)
    emit(opts, {:node_start, name})
    metadata = %{node: name}

    Runs.span([:lang_ex, :node, :execute], metadata, fn ->
      result =
        graph
        |> call_node(entry, entry_input(entry, state), opts)
        |> attach_entry(entry)

      emit_node_end(result, name, opts)
      {{name, result}, metadata}
    end)
  end

  defp attach_entry({:interrupted, interrupt, int_state}, entry),
    do: {:interrupted, Map.put(interrupt, :entry, entry), int_state}

  defp attach_entry(result, _entry), do: result

  defp emit_node_end({:interrupted, _, _}, _name, _opts), do: :ok
  defp emit_node_end({:graph_error, _}, _name, _opts), do: :ok
  defp emit_node_end(result, name, opts), do: emit(opts, {:node_end, name, result})

  defp reduce_task_result(_task_result, {:failed, _reason} = halt, _reducers), do: halt

  defp reduce_task_result(
         {{:ok, {_name, {:interrupted, interrupt, _int_state}}}, _entry},
         {acc, cmds, interrupts},
         _reducers
       ) do
    {acc, cmds, interrupts ++ [interrupt]}
  end

  defp reduce_task_result({{:ok, {_name, {:graph_error, reason}}}, _entry}, _acc, _reducers) do
    {:failed, reason}
  end

  defp reduce_task_result({{:ok, {name, result}}, _entry}, {acc, cmds, interrupts}, reducers) do
    {new_state, new_cmds} = merge_node_result(result, acc, reducers, cmds)
    {new_state, new_cmds, interrupts}
  rescue
    exception -> {:failed, NodeError.wrap(name, exception, __STACKTRACE__)}
  end

  defp reduce_task_result({{:exit, reason}, entry}, _acc, _reducers) do
    {:failed, exit_error(entry_name(entry), reason)}
  end

  defp exit_error(name, {exception, stacktrace}) when is_exception(exception),
    do: NodeError.wrap(name, exception, stacktrace)

  defp exit_error(name, reason), do: NodeError.wrap(name, reason, [])

  defp execute_single_node(graph, state, entry, opts) do
    name = entry_name(entry)
    emit(opts, {:node_start, name})
    metadata = %{node: name}

    Runs.span([:lang_ex, :node, :execute], metadata, fn ->
      graph
      |> call_node(entry, entry_input(entry, state), opts)
      |> attach_entry(entry)
      |> finalize_node_call(name, state, graph.reducers, opts, metadata)
    end)
  rescue
    exception ->
      {:graph_error, NodeError.wrap(entry_name(entry), exception, __STACKTRACE__)}
  end

  defp finalize_node_call(
         {:interrupted, _, _} = interrupt,
         _node_name,
         _state,
         _reducers,
         _opts,
         metadata
       ),
       do: {interrupt, metadata}

  defp finalize_node_call(
         {:graph_error, _reason} = error,
         _name,
         _state,
         _reducers,
         _opts,
         metadata
       ),
       do: {error, metadata}

  defp finalize_node_call(result, node_name, state, reducers, opts, metadata) do
    emit(opts, {:node_end, node_name, result})
    {merge_node_result(result, state, reducers, []), metadata}
  end

  defp call_node(graph, entry, state, opts) do
    name = entry_name(entry)
    node = fetch_node!(graph, name)
    policy = Map.get(graph.node_opts, name, [])
    prepare_node_context(entry, opts)

    try do
      run_with_policies(policy, node, entry, state, opts)
    catch
      :throw, {:lang_ex_interrupt, id, payload} ->
        {:interrupted, %{id: id, value: payload, node: name}, state}

      :throw, {:lang_ex_graph_error, reason} ->
        {:graph_error, reason}
    after
      clear_node_context()
    end
  end

  defp fetch_node!(graph, name) do
    graph.nodes
    |> Map.fetch(name)
    |> require_node!(name, graph)
  end

  defp require_node!({:ok, node}, _name, _graph), do: node

  defp require_node!(:error, name, graph) do
    raise ArgumentError,
          "cannot execute undefined node #{inspect(name)} — " <>
            "known nodes: #{inspect(Enum.sort(Map.keys(graph.nodes)))}. " <>
            "Check Command goto and Send targets."
  end

  defp run_with_policies(policy, node, entry, state, opts) do
    policy
    |> Keyword.get(:on_error)
    |> run_with_handler(policy, node, entry, state, opts)
  end

  # The error handler runs after the retry policy is exhausted; its
  # return value becomes the node result. Interrupts pass through.
  defp run_with_handler(nil, policy, node, entry, state, opts) do
    policy
    |> Keyword.get(:cache)
    |> run_cached(policy, node, entry, state, opts)
  end

  defp run_with_handler(handler, policy, node, entry, state, opts) do
    policy
    |> Keyword.get(:cache)
    |> run_cached(policy, node, entry, state, opts)
  rescue
    exception -> handler.(exception, state)
  end

  defp run_cached(nil, policy, node, entry, state, opts) do
    run_retried(policy, node, entry, state, opts)
  end

  defp run_cached(cache_opts, policy, node, entry, state, opts) do
    key = {entry_name(entry), :erlang.phash2({node, state})}

    key
    |> NodeCache.fetch({node, state})
    |> serve_cached(key, cache_opts, policy, node, entry, state, opts)
  end

  defp serve_cached({:ok, result}, _key, _cache_opts, _policy, _node, _entry, _state, _opts),
    do: result

  defp serve_cached(:miss, key, cache_opts, policy, node, entry, state, opts) do
    result = run_retried(policy, node, entry, state, opts)
    NodeCache.store(key, {node, state}, result, cache_ttl(cache_opts))
    result
  end

  defp cache_ttl(true), do: :infinity

  defp cache_ttl(cache_opts) when is_list(cache_opts),
    do: Keyword.get(cache_opts, :ttl, :infinity)

  defp run_retried(policy, node, entry, state, opts) do
    timeout = Keyword.get(policy, :timeout) || node_timeout(opts)

    policy
    |> Keyword.get(:retry)
    |> RetryPolicy.normalize()
    |> attempt_node(node, entry, state, opts, timeout, 1)
  end

  defp attempt_node(nil, node, entry, state, opts, timeout, _attempt),
    do: execute_attempt(timeout, node, entry, state, opts)

  defp attempt_node(retry, node, entry, state, opts, timeout, attempt) do
    Process.put(:lang_ex_interrupt_counter, 0)
    execute_attempt(timeout, node, entry, state, opts)
  rescue
    exception ->
      retry_or_reraise(
        retry,
        node,
        entry,
        state,
        opts,
        timeout,
        attempt,
        exception,
        __STACKTRACE__
      )
  end

  defp retry_or_reraise(retry, node, entry, state, opts, timeout, attempt, exception, stacktrace) do
    (attempt < retry.max_attempts and retry.retryable?.(exception))
    |> continue_retry(retry, node, entry, state, opts, timeout, attempt, exception, stacktrace)
  end

  defp continue_retry(true, retry, node, entry, state, opts, timeout, attempt, _exc, _stacktrace) do
    Process.sleep(RetryPolicy.delay_ms(retry, attempt))
    attempt_node(retry, node, entry, state, opts, timeout, attempt + 1)
  end

  defp continue_retry(
         false,
         _retry,
         _node,
         _entry,
         _state,
         _opts,
         _timeout,
         _attempt,
         exception,
         stacktrace
       ),
       do: reraise(exception, stacktrace)

  defp execute_attempt(:infinity, node, entry, state, opts),
    do: execute_node_value(node, entry_name(entry), state, opts)

  # A timed attempt runs in a supervised task with its own node context;
  # interrupt throws are re-thrown in the calling process so the regular
  # interrupt machinery in call_node/4 applies unchanged.
  defp execute_attempt(timeout, node, entry, state, opts) do
    parent_run_id = Runs.current_run_id()

    LangEx.TaskSupervisor
    |> Task.Supervisor.async_nolink(fn ->
      Runs.inherit_run_id(parent_run_id)
      prepare_node_context(entry, opts)
      catch_attempt_throws(node, entry_name(entry), state, opts)
    end)
    |> await_attempt(timeout, entry_name(entry))
  end

  defp catch_attempt_throws(node, name, state, opts) do
    {:completed, execute_node_value(node, name, state, opts)}
  catch
    :throw, thrown -> {:thrown, thrown}
  end

  defp await_attempt(task, timeout, name) do
    task
    |> Task.yield(timeout)
    |> settle_attempt(task, timeout, name)
  end

  defp settle_attempt(nil, task, timeout, name) do
    task
    |> Task.shutdown(:brutal_kill)
    |> settle_shutdown(timeout, name)
  end

  defp settle_attempt({:ok, {:completed, result}}, _task, _timeout, _name), do: result
  defp settle_attempt({:ok, {:thrown, thrown}}, _task, _timeout, _name), do: throw(thrown)

  defp settle_attempt({:exit, {exception, stacktrace}}, _task, _timeout, _name)
       when is_exception(exception),
       do: reraise(exception, stacktrace)

  defp settle_attempt({:exit, reason}, _task, _timeout, _name), do: exit(reason)

  defp settle_shutdown(nil, timeout, name),
    do: raise(NodeTimeoutError, node: name, timeout_ms: timeout)

  defp settle_shutdown(late_result, timeout, name),
    do: settle_attempt(late_result, nil, timeout, name)

  defp execute_node_value(%Compiled{} = subgraph, name, state, opts) do
    Process.delete(:lang_ex_parent_goto)

    result =
      subgraph
      |> start_subgraph(name, state, opts)
      |> unwrap_subgraph()

    :lang_ex_parent_goto
    |> Process.delete()
    |> attach_parent_goto(result)
  end

  defp execute_node_value(fun, _name, state, opts) when is_function(fun),
    do: invoke_node_fn(fun, state, opts.context)

  defp attach_parent_goto(nil, result), do: result

  defp attach_parent_goto(targets, result) when is_map(result),
    do: %Command{update: result, goto: targets}

  defp start_subgraph(subgraph, name, state, opts) do
    sub_opts = subgraph_opts(subgraph, name, opts)

    subgraph
    |> saved_subgraph_resume(sub_opts)
    |> run_subgraph(subgraph, state, sub_opts)
  end

  # A subgraph with its own checkpointer resumes from its namespaced
  # checkpoint when the resume values answer one of its pending
  # interrupts. Without a checkpointer the subgraph re-runs from
  # :__start__ with resume values injected — all pre-interrupt subgraph
  # nodes execute again, so their side effects must be idempotent.
  defp saved_subgraph_resume(%Compiled{checkpointer: nil}, _sub_opts), do: :fresh

  defp saved_subgraph_resume(%Compiled{checkpointer: cp}, sub_opts) do
    sub_opts
    |> Map.get(:resume_values, %{})
    |> load_resumable_checkpoint(cp, sub_opts.config)
  end

  defp load_resumable_checkpoint(values, _cp, _config) when values == %{}, do: :fresh

  defp load_resumable_checkpoint(values, cp, config) do
    config
    |> Keyword.get(:thread_id)
    |> load_saved_interrupt(cp, config)
    |> match_pending_resume(values)
  end

  defp load_saved_interrupt(nil, _cp, _config), do: :none
  defp load_saved_interrupt(_thread_id, cp, config), do: cp.load(config)

  defp match_pending_resume(
         {:ok, %Checkpoint{pending_interrupts: [_ | _] = pending} = saved},
         values
       ) do
    pending
    |> Enum.any?(&Map.has_key?(values, &1.id))
    |> resumable_checkpoint(saved)
  end

  defp match_pending_resume(_loaded, _values), do: :fresh

  defp resumable_checkpoint(true, saved), do: {:resume, saved}
  defp resumable_checkpoint(false, _saved), do: :fresh

  defp run_subgraph(:fresh, subgraph, state, sub_opts) do
    subgraph.initial_state
    |> State.apply_update(state, subgraph.reducers)
    |> then(&run(subgraph, &1, sub_opts))
  end

  defp run_subgraph({:resume, saved}, subgraph, _state, sub_opts) do
    {resume_state, overrides} =
      Compiled.resume_overrides(saved, Map.get(sub_opts, :resume_values, %{}))

    run(subgraph, resume_state, Map.merge(sub_opts, Map.new(overrides)))
  end

  defp subgraph_opts(subgraph, name, opts) do
    %{
      recursion_limit: opts.recursion_limit,
      checkpointer: subgraph.checkpointer,
      config: subgraph_config(opts.config, name),
      context: opts.context,
      resume: nil,
      resume_values: resume_values(opts),
      step: 0,
      emit_to: opts.emit_to,
      raw_interrupts: true,
      max_concurrency: Map.get(opts, :max_concurrency),
      node_timeout: Map.get(opts, :node_timeout),
      store: subgraph.store || Map.get(opts, :store),
      durability: Map.get(opts, :durability, :sync)
    }
  end

  defp subgraph_config(config, name) do
    config
    |> Keyword.get(:thread_id)
    |> namespace_thread(Keyword.delete(config, :checkpoint_id), name)
  end

  defp namespace_thread(nil, config, _name), do: config

  defp namespace_thread(thread_id, config, name),
    do: Keyword.put(config, :thread_id, "#{thread_id}/#{name}")

  defp unwrap_subgraph({:ok, result}), do: result

  # Re-throw with the inner interrupt id so id-addressed resume values
  # reach the interrupt call site when the subgraph re-runs.
  defp unwrap_subgraph({:interrupt, [%{id: id, value: payload} | _], _sub_state}),
    do: throw({:lang_ex_interrupt, id, payload})

  defp unwrap_subgraph({:error, reason}), do: throw({:lang_ex_graph_error, reason})

  defp prepare_node_context(entry, opts) do
    Process.put(:lang_ex_current_node, entry_name(entry))
    Process.put(:lang_ex_interrupt_counter, 0)
    Process.put(:lang_ex_resume_values, resume_values(opts))
    Process.put(:lang_ex_stream_emit, opts.emit_to)
    Process.put(:lang_ex_store, Map.get(opts, :store))
  end

  defp clear_node_context do
    Process.delete(:lang_ex_current_node)
    Process.delete(:lang_ex_interrupt_counter)
    Process.delete(:lang_ex_resume_values)
    Process.delete(:lang_ex_stream_emit)
    Process.delete(:lang_ex_store)
  end

  defp resume_values(%{resume: %{values: values}}), do: values
  defp resume_values(%{resume_values: values}) when is_map(values), do: values
  defp resume_values(_opts), do: %{}

  # Arity dispatch, not context presence, decides the call shape: an
  # arity-2 node receives the context (which may be nil when the run set
  # none), so context-aware nodes never crash on a context-less invoke.
  defp invoke_node_fn(fun, state, context) do
    fun
    |> Function.info(:arity)
    |> dispatch_node_fn(fun, state, context)
  end

  defp dispatch_node_fn({:arity, 2}, fun, state, context), do: fun.(state, context)
  defp dispatch_node_fn({:arity, 1}, fun, state, _context), do: fun.(state)

  defp merge_node_result(%Command{update: update, goto: goto}, state, reducers, cmds) do
    {State.apply_update(state, update, reducers), cmds ++ List.wrap(goto)}
  end

  defp merge_node_result(update, state, reducers, cmds) when is_map(update) do
    {State.apply_update(state, update, reducers), cmds}
  end

  defp resolve_next_nodes(graph, state, executed_entries, command_targets) do
    {parent_targets, local_targets} =
      Enum.split_with(command_targets, &match?({:parent, _}, &1))

    record_parent_goto(parent_targets)

    executed_entries
    |> Enum.flat_map(&resolve_targets(graph, entry_name(&1), state))
    |> then(&dedup_targets(local_targets ++ &1))
  end

  # `%Command{goto: {:parent, target}}` inside a subgraph routes the
  # *parent* graph: targets are collected here and re-attached as a
  # Command goto by the parent's subgraph node. Nested `{:parent,
  # {:parent, target}}` tuples bubble one level per graph boundary.
  defp record_parent_goto([]), do: :ok

  defp record_parent_goto(parent_targets) do
    recorded = Process.get(:lang_ex_parent_goto) || []
    Process.put(:lang_ex_parent_goto, recorded ++ Enum.map(parent_targets, &elem(&1, 1)))
    :ok
  end

  defp resolve_targets(graph, node, state) do
    [
      Map.get(graph.edges, node, []),
      graph.conditional_edges |> Map.fetch(node) |> resolve_conditional(state)
    ]
    |> List.flatten()
    |> dedup_targets()
  end

  # Duplicate Sends are distinct units of work and must all run;
  # only plain node targets are deduplicated.
  defp dedup_targets(targets) do
    {sends, nodes} = Enum.split_with(targets, &match?(%Send{}, &1))
    Enum.uniq(nodes) ++ sends
  end

  defp resolve_conditional(:error, _state), do: []

  defp resolve_conditional({:ok, {routing_fn, mapping}}, state) do
    state
    |> routing_fn.()
    |> dispatch_routing(mapping)
  end

  defp dispatch_routing([%Send{} | _] = sends, _mapping), do: sends
  defp dispatch_routing(result, mapping), do: resolve_routing_result(result, mapping)

  defp resolve_routing_result(result, nil) when is_atom(result), do: [result]
  defp resolve_routing_result(result, nil) when is_list(result), do: result

  defp resolve_routing_result(result, mapping) when is_map(mapping) do
    mapping
    |> Map.fetch(result)
    |> require_mapped_target!(result)
  end

  defp require_mapped_target!({:ok, target}, _result), do: List.wrap(target)

  defp require_mapped_target!(:error, result),
    do: raise(ArgumentError, "routing returned #{inspect(result)} but no mapping found")

  # The managed value is only injected (and stripped) when the user's
  # schema does not claim :remaining_steps for itself.
  defp inject_managed(state, %{recursion_limit: limit, step: step}) do
    state
    |> Map.has_key?(:remaining_steps)
    |> put_managed(state, limit - step)
  end

  defp put_managed(true, state, _remaining), do: state
  defp put_managed(false, state, remaining), do: Map.put(state, :remaining_steps, remaining)

  defp strip_managed(state, %Compiled{initial_state: initial}) do
    initial
    |> Map.has_key?(:remaining_steps)
    |> drop_managed(state)
  end

  defp drop_managed(true, state), do: state
  defp drop_managed(false, state), do: Map.delete(state, :remaining_steps)

  defp save_checkpoint(%{checkpointer: nil}, _state, _nodes), do: nil

  defp save_checkpoint(%{checkpointer: cp, config: config, step: step} = opts, state, nodes) do
    opts
    |> Map.get(:durability, :sync)
    |> save_step_checkpoint(opts, cp, config, step, state, nodes)
  end

  # :exit skips per-step checkpoints entirely — interrupts and the final
  # completion checkpoint still persist, so pause/resume works, but
  # crash recovery restarts from :__start__.
  defp save_step_checkpoint(:exit, _opts, _cp, _config, _step, _state, _nodes), do: nil

  defp save_step_checkpoint(durability, opts, cp, config, step, state, nodes) do
    config
    |> Keyword.get(:thread_id)
    |> persist_checkpoint(cp, config, durability,
      state: state,
      next_nodes: nodes,
      step: step,
      parent_id: Map.get(opts, :parent_id),
      metadata: %{}
    )
  end

  defp persist_checkpoint(nil, _cp, _config, _durability, _data), do: nil

  defp persist_checkpoint(thread_id, cp, config, durability, data) do
    checkpoint = Checkpoint.new([{:thread_id, thread_id} | data])
    write_checkpoint(durability, cp, config, checkpoint, thread_id)
    checkpoint.checkpoint_id
  end

  defp write_checkpoint(:sync, cp, config, checkpoint, thread_id) do
    metadata = %{checkpointer: cp, thread_id: thread_id}

    Runs.span([:lang_ex, :checkpoint, :save], metadata, fn ->
      {cp.save(config, checkpoint), metadata}
    end)
  end

  defp write_checkpoint(:async, cp, config, checkpoint, thread_id) do
    parent_run_id = Runs.current_run_id()

    {:ok, _pid} =
      Task.Supervisor.start_child(LangEx.TaskSupervisor, fn ->
        Runs.inherit_run_id(parent_run_id)
        write_checkpoint(:sync, cp, config, checkpoint, thread_id)
      end)

    :ok
  end

  defp save_interrupts(state, _pending, interrupts, _completed_next, %{checkpointer: nil} = opts) do
    interrupts
    |> interrupt_payload(opts)
    |> emit_interrupt(state, opts)
  end

  defp save_interrupts(
         state,
         pending,
         interrupts,
         completed_next,
         %{
           checkpointer: cp,
           config: config,
           step: step
         } = opts
       ) do
    config
    |> Keyword.get(:thread_id)
    |> persist_checkpoint(cp, config, :sync,
      state: state,
      next_nodes: pending,
      step: step,
      parent_id: Map.get(opts, :parent_id),
      pending_interrupts: interrupts,
      metadata: %{resume_values: resume_values(opts), completed_next: completed_next}
    )

    interrupts
    |> interrupt_payload(opts)
    |> emit_interrupt(state, opts)
  end

  defp emit_interrupt(payload, state, opts) do
    emit(opts, {:interrupt, payload})
    {:interrupt, payload, state}
  end

  defp interrupt_payload(interrupts, %{raw_interrupts: true}), do: interrupts
  defp interrupt_payload([%{value: value}], _opts), do: value
  defp interrupt_payload(interrupts, _opts), do: interrupts

  defp emit(%{emit_to: nil}, _event), do: :ok
  defp emit(%{emit_to: pid}, event), do: send(pid, {:lang_ex_stream, event})

  defp graph_invoke_metadata(graph, opts) do
    %{
      graph_id: graph.name || graph.nodes |> Map.keys() |> List.first(),
      thread_id: opts |> Map.get(:config, []) |> Keyword.get(:thread_id)
    }
  end

  defp result_tag({:ok, _}), do: :ok
  defp result_tag({:interrupt, _, _}), do: :interrupt
  defp result_tag({:error, _}), do: :error
end
