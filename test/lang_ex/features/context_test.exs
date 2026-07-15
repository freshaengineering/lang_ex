defmodule LangEx.Features.ContextTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph

  describe "runtime context" do
    test "arity-2 node receives context" do
      graph =
        Graph.new(greeting: "")
        |> Graph.add_node(:greet, fn state, context ->
          %{greeting: "Hello #{state.greeting} from #{context.provider}!"}
        end)
        |> Graph.add_edge(:__start__, :greet)
        |> Graph.add_edge(:greet, :__end__)
        |> Graph.compile()

      {:ok, result} = LangEx.invoke(graph, %{greeting: "World"}, context: %{provider: "OpenAI"})

      assert %{greeting: "Hello World from OpenAI!"} = result
    end

    test "arity-2 node receives nil context when the run sets none" do
      graph =
        Graph.new(seen: :unset)
        |> Graph.add_node(:capture, fn _state, context -> %{seen: context} end)
        |> Graph.add_edge(:__start__, :capture)
        |> Graph.add_edge(:capture, :__end__)
        |> Graph.compile()

      {:ok, result} = LangEx.invoke(graph, %{seen: :unset})

      assert %{seen: nil} = result
    end

    test "arity-1 node works with context present" do
      graph =
        Graph.new(x: 0)
        |> Graph.add_node(:inc, fn state -> %{x: state.x + 1} end)
        |> Graph.add_edge(:__start__, :inc)
        |> Graph.add_edge(:inc, :__end__)
        |> Graph.compile()

      {:ok, result} = LangEx.invoke(graph, %{x: 5}, context: %{ignored: true})

      assert %{x: 6} = result
    end
  end
end
