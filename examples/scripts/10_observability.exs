# Observability: reconstruct a full run tree from telemetry events.
#
# Every span (graph invoke -> super-step -> node -> LLM/checkpoint)
# carries a run_id and parent_run_id, so one invocation can be
# rebuilt as a tree — here rendered as an indented trace. The same
# events feed LangEx.Telemetry.OpenTelemetryBridge when the optional
# opentelemetry deps are installed.
#
# Run: elixir examples/scripts/10_observability.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule TraceCollector do
  alias LangEx.Graph

  def run do
    :telemetry.attach_many("trace", starts(), &__MODULE__.record/4, self())

    {:ok, _} = LangEx.invoke(build(), %{items: [4, 7]})

    spans = collect([])
    print_tree(spans, nil, 0)
  end

  def record(event, _measurements, metadata, pid) do
    send(pid, {:span, event, metadata})
  end

  defp starts do
    for event <- LangEx.Telemetry.events(),
        List.last(event) == :start,
        do: event
  end

  defp collect(acc) do
    receive do
      {:span, event, metadata} -> collect([{event, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp print_tree(spans, parent_id, depth) do
    spans
    |> Enum.filter(fn {_event, metadata} -> metadata.parent_run_id == parent_id end)
    |> Enum.each(fn {event, metadata} ->
      IO.puts(String.duplicate("  ", depth) <> describe(event, metadata))
      print_tree(spans, metadata.run_id, depth + 1)
    end)
  end

  defp describe([:lang_ex, :graph, :invoke, _], metadata), do: "invoke #{metadata.graph_id}"
  defp describe([:lang_ex, :graph, :step, _], metadata), do: "step #{metadata.step}"
  defp describe([:lang_ex, :node, :execute, _], metadata), do: "node #{metadata.node}"
  defp describe(event, _metadata), do: Enum.join(event, ".")

  defp build do
    Graph.new(items: [], doubled: {[], &Kernel.++/2}, sum: nil)
    |> Graph.add_node(:fan, fn _state -> %{} end)
    |> Graph.add_node(:double_a, fn state -> %{doubled: [Enum.at(state.items, 0) * 2]} end)
    |> Graph.add_node(:double_b, fn state -> %{doubled: [Enum.at(state.items, 1) * 2]} end)
    |> Graph.add_node(:sum, fn state -> %{sum: Enum.sum(state.doubled)} end)
    |> Graph.add_edge(:__start__, :fan)
    |> Graph.add_edge(:fan, :double_a)
    |> Graph.add_edge(:fan, :double_b)
    |> Graph.add_edge(:double_a, :sum)
    |> Graph.add_edge(:double_b, :sum)
    |> Graph.add_edge(:sum, :__end__)
    |> Graph.compile(name: :doubler)
  end
end

TraceCollector.run()
