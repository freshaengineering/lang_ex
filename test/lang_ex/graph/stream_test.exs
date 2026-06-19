defmodule LangEx.Graph.StreamTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph

  describe "streaming" do
    test "stream yields step events and done" do
      events =
        Graph.new(value: 0)
        |> Graph.add_node(:inc, fn state -> %{value: state.value + 1} end)
        |> Graph.add_edge(:__start__, :inc)
        |> Graph.add_edge(:inc, :__end__)
        |> Graph.compile()
        |> LangEx.stream(%{value: 0})
        |> Enum.to_list()
        |> Enum.group_by(&elem(&1, 0))

      assert map_size(Map.take(events, [:step_start])) >= 1
      assert map_size(Map.take(events, [:step_end])) >= 1
      assert [done: [{:done, {:ok, %{value: 1}}}]] = Map.take(events, [:done]) |> Enum.to_list()
    end

    test "stream yields node_start and node_end events" do
      events =
        Graph.new(text: "")
        |> Graph.add_node(:upper, fn state -> %{text: String.upcase(state.text)} end)
        |> Graph.add_edge(:__start__, :upper)
        |> Graph.add_edge(:upper, :__end__)
        |> Graph.compile()
        |> LangEx.stream(%{text: "hello"})
        |> Enum.to_list()

      assert Enum.any?(events, &match?({:node_start, :upper}, &1))
      assert Enum.any?(events, &match?({:node_end, :upper, _}, &1))
    end

    test "stream worker inherits $callers and $ancestors from the consumer" do
      caller = self()

      Graph.new(value: 0)
      |> Graph.add_node(:snapshot, fn state ->
        send(caller, {:callers, Process.get(:"$callers")})
        send(caller, {:ancestors, Process.get(:"$ancestors")})
        %{value: state.value + 1}
      end)
      |> Graph.add_edge(:__start__, :snapshot)
      |> Graph.add_edge(:snapshot, :__end__)
      |> Graph.compile()
      |> LangEx.stream(%{value: 0})
      |> Enum.to_list()

      assert_received {:callers, callers}
      assert_received {:ancestors, ancestors}
      assert caller in callers
      assert caller in ancestors
    end
  end
end
