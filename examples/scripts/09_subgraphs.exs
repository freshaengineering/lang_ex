# Subgraphs: a compiled graph is a node in another graph.
#
# Context, streaming events, and errors flow through the boundary,
# and an interrupt raised deep inside the subgraph pauses the parent —
# resuming the parent resumes through the subgraph.
#
# Run: elixir examples/scripts/09_subgraphs.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])
Code.require_file("support/in_memory_checkpointer.exs", __DIR__)

defmodule RefundDemo do
  alias Example.InMemoryCheckpointer
  alias LangEx.Command
  alias LangEx.Graph
  alias LangEx.Interrupt

  @config [thread_id: "refund-7"]

  def run do
    graph = build()

    {:interrupt, question, _state} =
      LangEx.invoke(graph, %{amount: 950}, config: @config)

    IO.puts("parent paused by subgraph: #{question}")

    {:ok, result} = LangEx.invoke(graph, %Command{resume: true}, config: @config)
    IO.puts(result.receipt)
  end

  # The approval flow is its own reusable graph...
  defp approval_subgraph do
    Graph.new(amount: 0, approved: nil)
    |> Graph.add_node(:review, fn state ->
      %{approved: Interrupt.interrupt("approve refund of $#{state.amount}?")}
    end)
    |> Graph.add_edge(:__start__, :review)
    |> Graph.add_edge(:review, :__end__)
    |> Graph.compile(name: :approval_flow)
  end

  # ...mounted as a single node in the parent graph.
  defp build do
    Graph.new(amount: 0, approved: nil, receipt: nil)
    |> Graph.add_node(:approval, approval_subgraph())
    |> Graph.add_node(:payout, fn state ->
      %{receipt: "refunded $#{state.amount} (approved: #{state.approved})"}
    end)
    |> Graph.add_edge(:__start__, :approval)
    |> Graph.add_edge(:approval, :payout)
    |> Graph.add_edge(:payout, :__end__)
    |> Graph.compile(name: :refund_flow, checkpointer: InMemoryCheckpointer)
  end
end

RefundDemo.run()
