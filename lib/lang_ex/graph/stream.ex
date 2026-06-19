defmodule LangEx.Graph.Stream do
  @moduledoc """
  Streaming graph execution.

  Returns an Elixir `Stream` that lazily yields events as the graph
  executes. Uses a spawned process that runs Pregel and sends events
  to the consumer via the mailbox.

  The streaming worker runs as a `Task`, which propagates `$callers`
  and `$ancestors` from the calling process. Libraries that rely on
  per-PID ownership (e.g. `Ecto.Adapters.SQL.Sandbox.allow/3`, custom
  per-test sandboxes, or process-dictionary-based stubs) see the
  consumer in the caller chain.

  ## Events

  - `{:node_start, node_name}` - a node is about to execute
  - `{:node_end, node_name, update}` - a node finished with this update
  - `{:step_start, step, active_nodes}` - a super-step begins
  - `{:step_end, step, state}` - a super-step completed
  - `{:interrupt, value}` - graph paused on interrupt
  - `{:done, result}` - graph finished with `{:ok, state}` or `{:error, ...}`
  """

  alias LangEx.Graph.Compiled
  alias LangEx.Graph.Pregel
  alias LangEx.Graph.State

  @doc "Returns a lazy stream of execution events from the compiled graph."
  @spec stream(Compiled.t(), map(), keyword()) :: Enumerable.t()
  def stream(%Compiled{} = graph, input, opts \\ []) do
    Stream.resource(
      fn -> start_execution(graph, input, opts) end,
      &receive_events/1,
      fn _ -> :ok end
    )
  end

  defp start_execution(graph, input, opts) do
    parent = self()

    {:ok, pid} =
      Task.start_link(fn ->
        state = State.apply_update(graph.initial_state, input, graph.reducers)

        graph
        |> Pregel.run(state, %{
          recursion_limit: Keyword.get(opts, :recursion_limit, 25),
          checkpointer: graph.checkpointer,
          config: Keyword.get(opts, :config, []),
          context: Keyword.get(opts, :context),
          resume: nil,
          step: 0,
          emit_to: parent
        })
        |> then(&send(parent, {:lang_ex_stream, {:done, &1}}))
      end)

    pid
  end

  defp receive_events(:halted), do: {:halt, :halted}

  defp receive_events(pid) do
    receive do
      {:lang_ex_stream, {:done, result}} ->
        {[{:done, result}], :halted}

      {:lang_ex_stream, event} ->
        {[event], pid}
    after
      5_000 -> {:halt, :halted}
    end
  end
end
