defmodule LangEx.Graph.Compiled do
  @moduledoc """
  A compiled, executable graph.

  Created by `LangEx.Graph.compile/1`. Use `invoke/2` to run the graph
  with an initial state input.
  """

  alias LangEx.Checkpoint
  alias LangEx.Graph.Pregel
  alias LangEx.Graph.State
  alias LangEx.Telemetry.Runs

  defstruct [
    :name,
    :nodes,
    :edges,
    :conditional_edges,
    :initial_state,
    :reducers,
    :checkpointer,
    interrupt_before: [],
    interrupt_after: []
  ]

  @type t :: %__MODULE__{
          name: atom() | String.t() | nil,
          nodes: %{atom() => (map() -> map()) | t()},
          edges: %{atom() => [atom()]},
          conditional_edges: %{atom() => {(map() -> atom() | String.t()), map() | nil}},
          initial_state: map(),
          reducers: State.reducers(),
          checkpointer: module() | nil,
          interrupt_before: [atom()],
          interrupt_after: [atom()]
        }

  @default_recursion_limit 25

  @doc """
  Executes the compiled graph with the given input state.

  With a checkpointer and a `:thread_id`, invoking with an empty input
  (`%{}`) continues an unfinished run from the last checkpoint's pending
  nodes instead of restarting from `:__start__` — this is how a crashed
  run is recovered. Non-empty input always starts a fresh pass from
  `:__start__`, merging the input into the latest checkpointed state.

  Options:
  - `:recursion_limit` - max super-steps before raising (default: #{@default_recursion_limit})
  - `:config` - keyword with `:thread_id` for checkpointing / resume
  - `:context` - runtime context passed to arity-2 node functions
  - `:max_concurrency` - cap on parallel node/Send tasks per super-step
    (default: `System.schedulers_online()`)
  - `:node_timeout` - per-node timeout in ms for parallel super-steps
    (default: `:infinity`)
  """
  @spec invoke(t(), map() | LangEx.Command.t(), keyword()) ::
          {:ok, map()} | {:interrupt, term(), map()} | {:error, term()}
  def invoke(graph, input, opts \\ [])

  def invoke(
        %__MODULE__{checkpointer: cp} = graph,
        %LangEx.Command{resume: resume_val},
        opts
      )
      when cp != nil and resume_val != nil do
    cp
    |> load_checkpoint(Keyword.get(opts, :config, []))
    |> resume_from_checkpoint(graph, resume_val, opts)
  end

  def invoke(%__MODULE__{checkpointer: cp} = graph, input, opts)
      when cp != nil and input == %{} do
    opts
    |> Keyword.get(:config, [])
    |> Keyword.get(:thread_id)
    |> continue_thread(graph, input, opts)
  end

  def invoke(%__MODULE__{} = graph, input, opts) when is_map(input) do
    start_fresh(graph, input, opts)
  end

  defp continue_thread(nil, graph, input, opts), do: start_fresh(graph, input, opts)

  defp continue_thread(_thread_id, graph, input, opts) do
    graph.checkpointer
    |> load_checkpoint(Keyword.get(opts, :config, []))
    |> continue_or_start(graph, input, opts)
  end

  defp continue_or_start(
         {:ok, %Checkpoint{pending_interrupts: nil, next_nodes: next} = saved},
         graph,
         input,
         opts
       ) do
    next
    |> Enum.reject(&(&1 == :__end__))
    |> continue_pending(saved, graph, input, opts)
  end

  defp continue_or_start(_loaded, graph, input, opts), do: start_fresh(graph, input, opts)

  defp continue_pending([], _saved, graph, input, opts), do: start_fresh(graph, input, opts)

  defp continue_pending(pending, saved, graph, _input, opts) do
    Pregel.run(
      graph,
      saved.state,
      build_run_opts(opts, graph,
        start_nodes: pending,
        step: saved.step + 1,
        parent_id: saved.checkpoint_id
      )
    )
  end

  defp start_fresh(graph, input, opts) do
    graph
    |> resolve_initial_state(input, opts)
    |> then(&Pregel.run(graph, &1, build_run_opts(opts, graph)))
  end

  @doc """
  Returns the latest checkpoint for a thread, or a specific one when
  `:checkpoint_id` is present in `:config`.

      Compiled.get_state(graph, config: [thread_id: "t-1"])
      Compiled.get_state(graph, config: [thread_id: "t-1", checkpoint_id: "abc"])
  """
  @spec get_state(t(), keyword()) :: {:ok, Checkpoint.t()} | :none | {:error, term()}
  def get_state(%__MODULE__{checkpointer: cp}, opts) when not is_nil(cp) do
    load_checkpoint(cp, Keyword.get(opts, :config, []))
  end

  @doc """
  Returns the checkpoint history for a thread, most recent first.

  Each checkpoint carries `parent_id`, so the full lineage (including
  forks created by `update_state/3`) can be reconstructed.

  Options: `:config` (with `:thread_id`), `:limit`.
  """
  @spec get_state_history(t(), keyword()) :: [Checkpoint.t()]
  def get_state_history(%__MODULE__{checkpointer: cp}, opts) when not is_nil(cp) do
    cp.list(Keyword.get(opts, :config, []), Keyword.take(opts, [:limit]))
  end

  @doc """
  Applies an update to a thread's checkpointed state and saves it as a
  new checkpoint whose parent is the loaded one.

  The update goes through the graph's reducers, exactly as a node
  result would. Loading a historical checkpoint via `:checkpoint_id`
  in `:config` forks the thread from that point. Returns the new
  checkpoint.
  """
  @spec update_state(t(), map(), keyword()) :: {:ok, Checkpoint.t()} | {:error, term()}
  def update_state(%__MODULE__{checkpointer: cp} = graph, update, opts) when not is_nil(cp) do
    config = Keyword.get(opts, :config, [])

    cp
    |> load_checkpoint(config)
    |> fork_checkpoint(graph, update, cp, config)
  end

  defp fork_checkpoint({:ok, %Checkpoint{} = saved}, graph, update, cp, config) do
    forked =
      Checkpoint.new(
        thread_id: saved.thread_id,
        parent_id: saved.checkpoint_id,
        state: State.apply_update(saved.state, update, graph.reducers),
        next_nodes: saved.next_nodes,
        step: saved.step,
        pending_interrupts: saved.pending_interrupts,
        metadata: saved.metadata
      )

    config
    |> cp.save(forked)
    |> forked_result(forked)
  end

  defp fork_checkpoint(:none, _graph, _update, _cp, _config), do: {:error, :no_checkpoint}
  defp fork_checkpoint({:error, _} = err, _graph, _update, _cp, _config), do: err

  defp forked_result(:ok, forked), do: {:ok, forked}
  defp forked_result({:error, _} = err, _forked), do: err

  defp resume_from_checkpoint(
         {:ok, %Checkpoint{pending_interrupts: [_ | _] = pending} = saved},
         graph,
         resume_val,
         opts
       ) do
    pending
    |> Enum.any?(&static_interrupt?/1)
    |> dispatch_resume(saved, graph, resume_val, opts)
  end

  defp resume_from_checkpoint(_, _graph, _resume_val, _opts),
    do: {:error, :no_pending_interrupt}

  defp static_interrupt?(%{static: true}), do: true
  defp static_interrupt?(_interrupt), do: false

  # Static breakpoints re-run the paused super-step (interrupt_before) or
  # continue with the already-resolved next nodes (interrupt_after); the
  # first resumed super-step bypasses breakpoints so it does not pause again.
  defp dispatch_resume(true, saved, graph, _resume_val, opts) do
    Pregel.run(
      graph,
      saved.state,
      opts
      |> build_run_opts(graph,
        start_nodes: saved.next_nodes,
        step: static_resume_step(saved),
        parent_id: saved.checkpoint_id
      )
      |> Map.put(:bypass_breakpoints, true)
    )
  end

  defp dispatch_resume(false, saved, graph, resume_val, opts) do
    values =
      saved
      |> saved_resume_values()
      |> Map.merge(normalize_resume(resume_val, saved.pending_interrupts))

    nodes = saved.pending_interrupts |> Enum.map(& &1.node) |> Enum.uniq()

    Pregel.run(
      graph,
      saved.state,
      build_run_opts(opts, graph,
        resume: %{nodes: nodes, values: values},
        step: saved.step,
        parent_id: saved.checkpoint_id
      )
    )
  end

  defp static_resume_step(
         %Checkpoint{pending_interrupts: [%{value: {:interrupt_after, _}} | _]} = saved
       ),
       do: saved.step + 1

  defp static_resume_step(saved), do: saved.step

  defp saved_resume_values(%Checkpoint{metadata: %{resume_values: values}}) when is_map(values),
    do: values

  defp saved_resume_values(_saved), do: %{}

  # A resume map is treated as id-addressed when it answers at least one
  # currently pending interrupt id; extra keys pre-answer future interrupts.
  # Any other value (including plain maps) answers the first pending interrupt.
  defp normalize_resume(by_id, pending) when is_map(by_id) and not is_struct(by_id) do
    pending
    |> Enum.any?(&Map.has_key?(by_id, &1.id))
    |> keyed_or_single(by_id, pending)
  end

  defp normalize_resume(value, [%{id: id} | _]), do: %{id => value}

  defp keyed_or_single(true, by_id, _pending), do: by_id
  defp keyed_or_single(false, value, [%{id: id} | _]), do: %{id => value}

  defp resolve_initial_state(graph, input, opts) do
    with cp when not is_nil(cp) <- graph.checkpointer,
         tid when not is_nil(tid) <- opts |> Keyword.get(:config, []) |> Keyword.get(:thread_id),
         {:ok, %Checkpoint{pending_interrupts: nil} = saved} <-
           load_checkpoint(cp, Keyword.get(opts, :config, [])) do
      State.apply_update(saved.state, input, graph.reducers)
    else
      _ -> State.apply_update(graph.initial_state, input, graph.reducers)
    end
  end

  defp load_checkpoint(cp, config) do
    metadata = %{checkpointer: cp, thread_id: Keyword.get(config, :thread_id)}

    Runs.span([:lang_ex, :checkpoint, :load], metadata, fn ->
      {cp.load(config), metadata}
    end)
  end

  defp build_run_opts(opts, graph, overrides \\ []) do
    %{
      recursion_limit: Keyword.get(opts, :recursion_limit, @default_recursion_limit),
      checkpointer: graph.checkpointer,
      config: Keyword.get(opts, :config, []),
      context: Keyword.get(opts, :context),
      resume: Keyword.get(overrides, :resume),
      step: Keyword.get(overrides, :step, 0),
      emit_to: nil,
      start_nodes: Keyword.get(overrides, :start_nodes),
      parent_id: Keyword.get(overrides, :parent_id),
      max_concurrency: Keyword.get(opts, :max_concurrency),
      node_timeout: Keyword.get(opts, :node_timeout)
    }
  end
end
