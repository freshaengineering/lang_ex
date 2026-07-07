defmodule LangEx.Features.SubgraphTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph

  describe "subgraphs" do
    test "compiled graph can be used as a node in a parent graph" do
      inner =
        Graph.new(value: 0)
        |> Graph.add_node(:double, fn state -> %{value: state.value * 2} end)
        |> Graph.add_edge(:__start__, :double)
        |> Graph.add_edge(:double, :__end__)
        |> Graph.compile()

      outer =
        Graph.new(value: 0, label: "")
        |> Graph.add_node(:sub, inner)
        |> Graph.add_node(:tag, fn _state -> %{label: "done"} end)
        |> Graph.add_edge(:__start__, :sub)
        |> Graph.add_edge(:sub, :tag)
        |> Graph.add_edge(:tag, :__end__)
        |> Graph.compile()

      {:ok, result} = LangEx.invoke(outer, %{value: 7})

      assert %{value: 14, label: "done"} = result
    end

    test "interrupts inside a subgraph pause the parent and resume through it" do
      inner =
        Graph.new(value: 0, approved: nil)
        |> Graph.add_node(:approve, fn _state ->
          %{approved: LangEx.Interrupt.interrupt("approve inner?")}
        end)
        |> Graph.add_edge(:__start__, :approve)
        |> Graph.add_edge(:approve, :__end__)
        |> Graph.compile()

      outer =
        Graph.new(value: 0, approved: nil, label: "")
        |> Graph.add_node(:sub, inner)
        |> Graph.add_node(:tag, fn _state -> %{label: "done"} end)
        |> Graph.add_edge(:__start__, :sub)
        |> Graph.add_edge(:sub, :tag)
        |> Graph.add_edge(:tag, :__end__)
        |> Graph.compile(checkpointer: LangEx.Checkpointer.Mock)

      config = [thread_id: "subgraph-interrupt-1"]

      {:interrupt, "approve inner?", _paused} = LangEx.invoke(outer, %{value: 7}, config: config)

      {:ok, result} =
        LangEx.invoke(outer, %LangEx.Command{resume: true}, config: config)

      assert %{approved: true, label: "done"} = result
    end

    test "errors inside a subgraph surface as parent errors" do
      inner =
        Graph.new(value: 0)
        |> Graph.add_node(:loop, fn state -> %{value: state.value + 1} end)
        |> Graph.add_edge(:__start__, :loop)
        |> Graph.add_edge(:loop, :loop)
        |> Graph.compile()

      outer =
        Graph.new(value: 0)
        |> Graph.add_node(:sub, inner)
        |> Graph.add_edge(:__start__, :sub)
        |> Graph.add_edge(:sub, :__end__)
        |> Graph.compile()

      assert {:error, {:recursion_limit, _, _}} = LangEx.invoke(outer, %{value: 0})
    end

    test "runtime context reaches nodes inside a subgraph" do
      inner =
        Graph.new(greeting: nil)
        |> Graph.add_node(:greet, fn _state, context ->
          %{greeting: "hello from #{context.provider}"}
        end)
        |> Graph.add_edge(:__start__, :greet)
        |> Graph.add_edge(:greet, :__end__)
        |> Graph.compile()

      outer =
        Graph.new(greeting: nil)
        |> Graph.add_node(:sub, inner)
        |> Graph.add_edge(:__start__, :sub)
        |> Graph.add_edge(:sub, :__end__)
        |> Graph.compile()

      {:ok, result} = LangEx.invoke(outer, %{}, context: %{provider: "outer"})

      assert %{greeting: "hello from outer"} = result
    end

    test "subgraph node events appear in the parent stream" do
      inner =
        Graph.new(value: 0)
        |> Graph.add_node(:inner_inc, fn state -> %{value: state.value + 1} end)
        |> Graph.add_edge(:__start__, :inner_inc)
        |> Graph.add_edge(:inner_inc, :__end__)
        |> Graph.compile()

      outer =
        Graph.new(value: 0)
        |> Graph.add_node(:sub, inner)
        |> Graph.add_edge(:__start__, :sub)
        |> Graph.add_edge(:sub, :__end__)
        |> Graph.compile()

      events = outer |> LangEx.stream(%{value: 0}) |> Enum.to_list()

      assert Enum.any?(events, &match?({:node_start, :inner_inc}, &1))
      assert Enum.any?(events, &match?({:node_start, :sub}, &1))
    end
  end
end
