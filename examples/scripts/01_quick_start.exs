# Quick start: nodes, edges, conditional routing, and state reducers.
#
# Run: elixir examples/scripts/01_quick_start.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

alias LangEx.Graph

defmodule Intent do
  def of(text), do: pick(String.contains?(text, "weather"))

  defp pick(true), do: :weather
  defp pick(false), do: :greeting
end

# State schema: `log` accumulates via a reducer; `intent`/`reply` are last-write-wins.
graph =
  Graph.new(log: {[], &Kernel.++/2}, intent: nil, reply: nil)
  |> Graph.add_node(:classify, fn state ->
    %{intent: Intent.of(hd(state.log)), log: ["classified"]}
  end)
  |> Graph.add_node(:weather, fn _state ->
    %{reply: "It's 22°C and sunny.", log: ["answered weather"]}
  end)
  |> Graph.add_node(:greet, fn _state ->
    %{reply: "Hello there!", log: ["greeted"]}
  end)
  |> Graph.add_edge(:__start__, :classify)
  |> Graph.add_conditional_edges(:classify, & &1.intent, %{
    weather: :weather,
    greeting: :greet
  })
  |> Graph.add_edge(:weather, :__end__)
  |> Graph.add_edge(:greet, :__end__)
  |> Graph.compile(name: :quick_start)

{:ok, result} = LangEx.invoke(graph, %{log: ["what's the weather like?"]})

IO.puts("intent: #{result.intent}")
IO.puts("reply:  #{result.reply}")
IO.puts("log:    #{inspect(result.log)}")
