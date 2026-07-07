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

  Streaming accepts the same inputs as `LangEx.invoke/3`: a map to start
  a run, `%{}` to continue a crashed thread, or `%LangEx.Command{resume:
  value}` to resume an interrupted one.

  ## Stream modes

  Pass `modes: [...]` to select event granularity (default `[:updates]`):

  - `:updates` — per-node/per-step events (the event list below)
  - `:values` — `{:values, state}` with the full state after each super-step
  - `:messages` — `{:message_delta, %{node: name, kind: :content, text: chunk}}`
    token deltas forwarded from streaming LLM adapters via `ChatModel`
  - `:custom` — `{:custom, term}` events emitted by nodes with `emit/1`

  `{:interrupt, value}` and the final `{:done, result}` are always
  delivered regardless of mode.

  ## `:updates` events

  - `{:step_start, step, active_nodes}` - a super-step begins
  - `{:node_start, node_name}` - a node is about to execute
  - `{:node_end, node_name, update}` - a node finished with this update
  - `{:step_end, step, state}` - a super-step completed
  """

  alias LangEx.Graph.Compiled
  alias LangEx.Graph.Pregel
  alias LangEx.Telemetry.Runs

  @always_delivered [:interrupt, :done]

  @doc """
  Returns a lazy stream of execution events from the compiled graph.

  Accepts the same options as `LangEx.invoke/3` plus `:modes`.
  """
  @spec stream(Compiled.t(), map() | LangEx.Command.t(), keyword()) :: Enumerable.t()
  def stream(%Compiled{} = graph, input, opts \\ []) do
    modes = opts |> Keyword.get(:modes, [:updates]) |> List.wrap()

    Stream.resource(
      fn -> {start_execution(graph, input, opts), modes} end,
      &receive_events/1,
      &stop_execution/1
    )
  end

  @doc """
  Emits a custom event into the enclosing run's event stream.

  Call from inside a node function; consumers see `{:custom, event}`
  when streaming with the `:custom` mode. A no-op when the graph is
  executed with `invoke/3` instead of `stream/3`.
  """
  @spec emit(term()) :: :ok
  def emit(event), do: notify({:custom, event})

  @doc false
  @spec notify(term()) :: :ok
  def notify(event) do
    :lang_ex_stream_emit
    |> Process.get()
    |> send_event(event)
  end

  defp send_event(nil, _event), do: :ok

  defp send_event(pid, event) do
    send(pid, {:lang_ex_stream, event})
    :ok
  end

  defp start_execution(graph, input, opts) do
    parent = self()
    parent_run_id = Runs.current_run_id()

    Task.Supervisor.async_nolink(LangEx.TaskSupervisor, fn ->
      Runs.inherit_run_id(parent_run_id)

      graph
      |> Compiled.prepare_run(input, opts)
      |> run_prepared(graph, parent)
      |> then(&send(parent, {:lang_ex_stream, {:done, &1}}))
    end)
  end

  defp run_prepared({:run, state, run_opts}, graph, parent),
    do: Pregel.run(graph, state, %{run_opts | emit_to: parent})

  defp run_prepared({:error, _} = err, _graph, _parent), do: err

  defp receive_events(:halted), do: {:halt, :halted}

  defp receive_events({%Task{ref: ref} = task, modes}) do
    receive do
      {:lang_ex_stream, {:done, result}} ->
        {deliver({:done, result}, modes), await_completion(task)}

      {:lang_ex_stream, event} ->
        {deliver(event, modes), {task, modes}}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {[{:done, {:error, {:runner_exit, reason}}}], :halted}
    end
  end

  defp deliver({tag, _} = event, _modes) when tag in @always_delivered, do: [event]

  defp deliver({:step_end, _step, state} = event, modes),
    do: for_mode(event, :updates, modes) ++ for_mode({:values, state}, :values, modes)

  defp deliver({:custom, _} = event, modes), do: for_mode(event, :custom, modes)
  defp deliver({:message_delta, _} = event, modes), do: for_mode(event, :messages, modes)
  defp deliver(event, modes), do: for_mode(event, :updates, modes)

  defp for_mode(event, mode, modes) do
    modes
    |> Enum.member?(mode)
    |> include(event)
  end

  defp include(true, event), do: [event]
  defp include(false, _event), do: []

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
  defp stop_execution({%Task{} = task, _modes}), do: Task.shutdown(task, :brutal_kill)
end
