# Time travel: inspect checkpoint history, edit state, fork a thread.
#
# Every super-step saves a checkpoint with a parent_id, forming a
# lineage. `get_state_history/2` lists them, `update_state/3` forks a
# new checkpoint from any point, and invoking with `%{}` continues
# from the edited state.
#
# Run: elixir examples/scripts/07_time_travel.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])
Code.require_file("support/in_memory_checkpointer.exs", __DIR__)

defmodule TimeTravelDemo do
  alias Example.InMemoryCheckpointer
  alias LangEx.Graph

  @config [thread_id: "trip-1"]

  def run do
    graph = build()

    {:ok, %{total: 132}} = LangEx.invoke(graph, %{nights: 2}, config: @config)

    IO.puts("history (most recent first):")

    graph
    |> LangEx.get_state_history(config: @config)
    |> Enum.each(fn cp ->
      IO.puts("  step #{cp.step} #{cp.checkpoint_id} (parent: #{cp.parent_id || "-"})")
      IO.puts("    state: #{inspect(cp.state)}")
    end)

    # Rewind: fork from the latest checkpoint with corrected input...
    {:ok, forked} = LangEx.update_state(graph, %{nights: 5}, config: @config)
    IO.puts("\nforked #{forked.checkpoint_id} with nights: 5")

    # ...and re-run the thread from the edited state.
    {:ok, result} = LangEx.invoke(graph, %{nights: 5}, config: @config)
    IO.puts("re-quoted total: #{result.total}")
  end

  defp build do
    Graph.new(nights: 0, price: nil, total: nil)
    |> Graph.add_node(:quote, fn state -> %{price: state.nights * 50 + 20} end)
    |> Graph.add_node(:tax, fn state -> %{total: round(state.price * 1.1)} end)
    |> Graph.add_edge(:__start__, :quote)
    |> Graph.add_edge(:quote, :tax)
    |> Graph.add_edge(:tax, :__end__)
    |> Graph.compile(name: :trip_quoter, checkpointer: InMemoryCheckpointer)
  end
end

TimeTravelDemo.run()
