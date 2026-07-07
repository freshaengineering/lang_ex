defmodule LangEx.Features.SendTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph
  alias LangEx.Send

  describe "Send fan-out" do
    test "merges each Send result into shared state via reducers" do
      graph =
        Graph.new(results: {[], &Kernel.++/2})
        |> Graph.add_node(:setup, fn _state -> %{} end)
        |> Graph.add_node(:worker, fn state ->
          %{results: [state.item]}
        end)
        |> Graph.add_edge(:__start__, :setup)
        |> Graph.add_conditional_edges(:setup, fn _state ->
          [
            %Send{node: :worker, state: %{item: "a"}},
            %Send{node: :worker, state: %{item: "b"}}
          ]
        end)
        |> Graph.add_edge(:worker, :__end__)
        |> Graph.compile()

      {:ok, %{results: results}} = LangEx.invoke(graph, %{})

      assert Enum.sort(results) == ["a", "b"]
    end

    test "duplicate Sends all run" do
      graph =
        Graph.new(total: {0, &Kernel.+/2})
        |> Graph.add_node(:setup, fn _state -> %{} end)
        |> Graph.add_node(:worker, fn state -> %{total: state.amount} end)
        |> Graph.add_edge(:__start__, :setup)
        |> Graph.add_conditional_edges(:setup, fn _state ->
          [
            %Send{node: :worker, state: %{amount: 5}},
            %Send{node: :worker, state: %{amount: 5}}
          ]
        end)
        |> Graph.add_edge(:worker, :__end__)
        |> Graph.compile()

      assert {:ok, %{total: 10}} = LangEx.invoke(graph, %{})
    end

    test "Send targets continue through their outgoing edges" do
      graph =
        Graph.new(results: {[], &Kernel.++/2}, summary: nil)
        |> Graph.add_node(:setup, fn _state -> %{} end)
        |> Graph.add_node(:worker, fn state -> %{results: [state.item]} end)
        |> Graph.add_node(:collect, fn state ->
          %{summary: state.results |> Enum.sort() |> Enum.join(",")}
        end)
        |> Graph.add_edge(:__start__, :setup)
        |> Graph.add_conditional_edges(:setup, fn _state ->
          [
            %Send{node: :worker, state: %{item: "a"}},
            %Send{node: :worker, state: %{item: "b"}}
          ]
        end)
        |> Graph.add_edge(:worker, :collect)
        |> Graph.add_edge(:collect, :__end__)
        |> Graph.compile()

      assert {:ok, %{summary: "a,b"}} = LangEx.invoke(graph, %{})
    end
  end
end
