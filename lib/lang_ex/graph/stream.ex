defmodule LangEx.Graph.Stream do
  @moduledoc """
  Streaming graph execution.

  Returns an Elixir `Stream` that lazily yields events as the graph
  executes. Execution runs in a supervised, monitored task that sends
  events to the consumer via the mailbox. The stream blocks until the
  next event arrives — long-running nodes (e.g. LLM calls) never cause
  the stream to halt early. If the runner crashes, the crash is surfaced
  as a `{:done, {:error, {:runner_exit, reason}}}` event. Halting the
  stream early shuts the runner down.

  ## Events

  - `{:node_start, node_name}` - a node is about to execute
  - `{:node_end, node_name, update}` - a node finished with this update
  - `{:step_start, step, active_nodes}` - a super-step begins
  - `{:step_end, step, state}` - a super-step completed
  - `{:interrupt, value}` - graph paused on interrupt
  - `{:done, result}` - graph finished with `{:ok, state}`, `{:interrupt, ...}`,
    or `{:error, ...}` (including `{:error, {:runner_exit, reason}}` on crash)
  """

  alias LangEx.Graph.Compiled
  alias LangEx.Graph.Pregel
  alias LangEx.Graph.State
  alias LangEx.Telemetry.Runs

  @doc "Returns a lazy stream of execution events from the compiled graph."
  @spec stream(Compiled.t(), map(), keyword()) :: Enumerable.t()
  def stream(%Compiled{} = graph, input, opts \\ []) do
    Stream.resource(
      fn -> start_execution(graph, input, opts) end,
      &receive_events/1,
      &stop_execution/1
    )
  end

  defp start_execution(graph, input, opts) do
    parent = self()
    parent_run_id = Runs.current_run_id()

    Task.Supervisor.async_nolink(LangEx.TaskSupervisor, fn ->
      Runs.inherit_run_id(parent_run_id)
      state = State.apply_update(graph.initial_state, input, graph.reducers)

      graph
      |> Pregel.run(state, %{
        recursion_limit: Keyword.get(opts, :recursion_limit, 25),
        checkpointer: graph.checkpointer,
        config: Keyword.get(opts, :config, []),
        context: Keyword.get(opts, :context),
        resume: nil,
        step: 0,
        emit_to: parent,
        max_concurrency: Keyword.get(opts, :max_concurrency),
        node_timeout: Keyword.get(opts, :node_timeout)
      })
      |> then(&send(parent, {:lang_ex_stream, {:done, &1}}))
    end)
  end

  defp receive_events(:halted), do: {:halt, :halted}

  defp receive_events(%Task{ref: ref} = task) do
    receive do
      {:lang_ex_stream, {:done, result}} ->
        {[{:done, result}], await_completion(task)}

      {:lang_ex_stream, event} ->
        {[event], task}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {[{:done, {:error, {:runner_exit, reason}}}], :halted}
    end
  end

  defp await_completion(%Task{ref: ref} = task) do
    receive do
      {^ref, _result} ->
        Process.demonitor(ref, [:flush])
        :halted

      {:DOWN, ^ref, :process, _pid, _reason} ->
        :halted
    after
      5_000 ->
        Task.shutdown(task, :brutal_kill)
        :halted
    end
  end

  defp stop_execution(:halted), do: :ok
  defp stop_execution(%Task{} = task), do: Task.shutdown(task, :brutal_kill)
end
