# Managing a thread over its whole life: read it, branch it, delete it.
#
# A long-running conversation accumulates checkpoints. Four operations
# make that history usable rather than just large:
#
#   get_state_history/2 with source:   read only the branch points
#   get_state_history/2 with before:   page back through a long history
#   copy_thread/3:                     branch a live thread, safely
#   delete_thread/2:                   close it out, subgraphs included
#
# This one uses the built-in `LangEx.Checkpointer.Memory` because copying
# is an optional callback the example template does not implement.
#
# Run: elixir examples/scripts/17_thread_lifecycle.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule ThreadLifecycleDemo do
  alias LangEx.Checkpointer.Memory
  alias LangEx.Graph

  @config [thread_id: "quote-1"]

  def run do
    graph = build()

    # A few turns of the same thread, plus a hand edit.
    {:ok, _} = LangEx.invoke(graph, %{items: 2}, config: @config)
    {:ok, _} = LangEx.invoke(graph, %{items: 3}, config: @config)
    {:ok, _} = LangEx.update_state(graph, %{discount: 10}, config: @config)
    {:ok, _} = LangEx.invoke(graph, %{items: 4}, config: @config)

    full = LangEx.get_state_history(graph, config: @config)
    IO.puts("#{length(full)} checkpoints: #{full |> Enum.map(& &1.source) |> inspect()}")

    # Provenance turns the history into an audit trail: which turns did a
    # human alter, as opposed to the engine advancing a step?
    edits = LangEx.get_state_history(graph, config: @config, source: [:update, :fork])
    IO.puts("human edits: #{length(edits)}")

    # `before:` is a cursor, so a long history pages without loading it
    # all — page 2 starts after the last checkpoint of page 1.
    page_1 = LangEx.get_state_history(graph, config: @config, limit: 3)
    page_2 = LangEx.get_state_history(graph, config: @config, limit: 3, before: cursor(page_1))

    IO.puts("page 1: #{describe(page_1)}")
    IO.puts("page 2: #{describe(page_2)}")

    # Branch the thread to try something out. The copy carries the full
    # history, so it can be rewound and replayed on its own.
    :ok = LangEx.copy_thread(graph, "quote-1-what-if", config: @config)
    branch = [thread_id: "quote-1-what-if"]

    {:ok, _} = LangEx.update_state(graph, %{discount: 40}, config: branch)
    {:ok, explored} = LangEx.invoke(graph, %{items: 4}, config: branch)
    {:ok, original} = LangEx.get_state(graph, config: @config)

    IO.puts("\nbranch total:   #{explored.total} (discount #{explored.discount}%)")
    IO.puts("original total: #{original.state.total} (discount #{original.state.discount}%)")

    # Closing the conversation removes the thread and every namespace
    # under it — the pricing subgraph keeps its own history under this
    # thread ID, and a delete that missed it would leave orphans behind.
    IO.puts(
      "\nbefore delete — root: #{count(graph, @config)}, price ns: #{subgraph_count(graph)}"
    )

    :ok = LangEx.delete_thread(graph, config: @config)
    IO.puts("after delete  — root: #{count(graph, @config)}, price ns: #{subgraph_count(graph)}")
    IO.puts("the branch still has #{count(graph, branch)} checkpoints")
  end

  defp build do
    Graph.new(items: 0, discount: 0, total: nil)
    |> Graph.add_node(:price, pricing_subgraph())
    |> Graph.add_edge(:__start__, :price)
    |> Graph.add_edge(:price, :__end__)
    |> Graph.compile(name: :quoter, checkpointer: Memory)
  end

  # Mounted as a node with a checkpointer of its own, so it keeps history
  # under the parent's thread ID in the "price" namespace.
  defp pricing_subgraph do
    Graph.new(items: 0, discount: 0, total: nil)
    |> Graph.add_node(:total, fn state ->
      %{total: round(state.items * 100 * (100 - state.discount) / 100)}
    end)
    |> Graph.add_edge(:__start__, :total)
    |> Graph.add_edge(:total, :__end__)
    |> Graph.compile(name: :pricing, checkpointer: Memory)
  end

  defp cursor(page), do: page |> List.last() |> Map.fetch!(:checkpoint_id)

  # Step numbers restart with each invoke, so identify checkpoints by ID.
  defp describe(page) do
    page
    |> Enum.map(&"#{String.slice(&1.checkpoint_id, 0, 6)}/#{&1.source}")
    |> Enum.join(", ")
  end

  defp count(graph, config), do: graph |> LangEx.get_state_history(config: config) |> length()

  defp subgraph_count(graph),
    do: count(graph, Keyword.put(@config, :checkpoint_ns, "price"))
end

ThreadLifecycleDemo.run()
