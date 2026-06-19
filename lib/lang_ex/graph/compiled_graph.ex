defmodule LangEx.Graph.Compiled do
  @moduledoc """
  A compiled, executable graph.

  Created by `LangEx.Graph.compile/1`. Use `invoke/2` to run the graph
  with an initial state input.
  """

  alias LangEx.Checkpoint
  alias LangEx.Graph.Pregel
  alias LangEx.Graph.State

  defstruct [
    :nodes,
    :edges,
    :conditional_edges,
    :initial_state,
    :reducers,
    :checkpointer
  ]

  @type t :: %__MODULE__{
          nodes: %{atom() => (map() -> map())},
          edges: %{atom() => [atom()]},
          conditional_edges: %{atom() => {(map() -> atom() | String.t()), map() | nil}},
          initial_state: map(),
          reducers: State.reducers(),
          checkpointer: module() | nil
        }

  @default_recursion_limit 25

  @doc """
  Executes the compiled graph with the given input state.

  Options:
  - `:recursion_limit` - max super-steps before raising (default: #{@default_recursion_limit})
  - `:config` - keyword with `:thread_id` for checkpointing / resume
  - `:context` - runtime context passed to arity-2 node functions
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

  def invoke(%__MODULE__{} = graph, input, opts) when is_map(input) do
    graph
    |> resolve_initial_state(input, opts)
    |> then(&Pregel.run(graph, &1, build_run_opts(opts, graph)))
  end

  defp resume_from_checkpoint(
         {:ok, %Checkpoint{pending_interrupts: [%{node: node} | _]} = saved},
         graph,
         resume_val,
         opts
       ) do
    Pregel.run(
      graph,
      saved.state,
      build_run_opts(opts, graph, resume: %{node: node, value: resume_val}, step: saved.step)
    )
  end

  # Recovery from a stuck checkpoint: graph stopped mid-execution at a
  # non-interrupt node. Latest checkpoint has queued `next_nodes` but no
  # pending interrupt. Continue from those queued nodes (the resume
  # value is discarded — there is no interrupt to feed it to).
  defp resume_from_checkpoint(
         {:ok, %Checkpoint{pending_interrupts: pending, next_nodes: next_nodes} = saved},
         graph,
         _resume_val,
         opts
       )
       when (is_nil(pending) or pending === []) and is_list(next_nodes) do
    case Enum.reject(next_nodes, &(&1 === :__end__)) do
      [] ->
        {:error, :no_pending_interrupt}

      runnable ->
        Pregel.run(
          graph,
          saved.state,
          build_run_opts(opts, graph, next_nodes: runnable, step: saved.step)
        )
    end
  end

  defp resume_from_checkpoint(_, _graph, _resume_val, _opts),
    do: {:error, :no_pending_interrupt}

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

    :telemetry.span([:lang_ex, :checkpoint, :load], metadata, fn ->
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
      next_nodes: Keyword.get(overrides, :next_nodes)
    }
  end
end
