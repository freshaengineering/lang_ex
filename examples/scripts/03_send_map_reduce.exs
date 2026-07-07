# Send fan-out: dynamic map-reduce with bounded concurrency.
#
# A conditional edge returns `%LangEx.Send{}` structs — one per work
# item — so the number of parallel branches is decided at runtime.
# Each worker result merges into shared state through the reducers,
# and `max_concurrency` caps how many run at once.
#
# Run: elixir examples/scripts/03_send_map_reduce.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule MapReduceDemo do
  alias LangEx.Graph
  alias LangEx.Send

  def run do
    urls = ["a.example", "b.example", "c.example", "d.example"]

    {:ok, result} =
      LangEx.invoke(build(), %{urls: urls}, max_concurrency: 2, node_timeout: 5_000)

    Enum.each(Enum.sort(result.summaries), &IO.puts("  #{&1}"))
    IO.puts(result.report)
  end

  defp build do
    Graph.new(urls: [], summaries: {[], &Kernel.++/2}, report: nil)
    |> Graph.add_node(:plan, fn _state -> %{} end)
    |> Graph.add_node(:crawl, &crawl/1)
    |> Graph.add_node(:report, fn state ->
      %{report: "crawled #{length(state.summaries)} pages"}
    end)
    |> Graph.add_edge(:__start__, :plan)
    |> Graph.add_conditional_edges(:plan, &fan_out/1)
    |> Graph.add_edge(:crawl, :report)
    |> Graph.add_edge(:report, :__end__)
    |> Graph.compile(name: :map_reduce_demo)
  end

  # One Send per URL — each runs :crawl with its own payload.
  defp fan_out(state), do: Enum.map(state.urls, &%Send{node: :crawl, state: %{url: &1}})

  defp crawl(state) do
    Process.sleep(50)
    %{summaries: ["#{state.url}: 200 OK"]}
  end
end

MapReduceDemo.run()
