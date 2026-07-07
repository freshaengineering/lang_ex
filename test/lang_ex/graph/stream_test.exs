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

    test "stream keeps yielding while a node is slow" do
      events =
        Graph.new(value: 0)
        |> Graph.add_node(:slow, fn state ->
          Process.sleep(150)
          %{value: state.value + 1}
        end)
        |> Graph.add_edge(:__start__, :slow)
        |> Graph.add_edge(:slow, :__end__)
        |> Graph.compile()
        |> LangEx.stream(%{value: 0})
        |> Enum.to_list()

      assert [{:done, {:ok, %{value: 1}}}] = Enum.filter(events, &match?({:done, _}, &1))
    end

    @tag :capture_log
    test "runner crash surfaces as an error done event" do
      events =
        Graph.new(value: 0)
        |> Graph.add_node(:boom, fn _state -> raise "kaboom" end)
        |> Graph.add_edge(:__start__, :boom)
        |> Graph.add_edge(:boom, :__end__)
        |> Graph.compile()
        |> LangEx.stream(%{value: 0})
        |> Enum.to_list()

      assert [{:done, {:error, {:runner_exit, {%RuntimeError{message: "kaboom"}, _}}}}] =
               Enum.filter(events, &match?({:done, _}, &1))
    end

    test "halting the stream early shuts the runner down" do
      test_pid = self()

      Graph.new(value: 0)
      |> Graph.add_node(:first, fn state -> %{value: state.value + 1} end)
      |> Graph.add_node(:second, fn state ->
        Process.sleep(200)
        send(test_pid, :second_ran)
        %{value: state.value + 1}
      end)
      |> Graph.add_edge(:__start__, :first)
      |> Graph.add_edge(:first, :second)
      |> Graph.add_edge(:second, :__end__)
      |> Graph.compile()
      |> LangEx.stream(%{value: 0})
      |> Enum.take(1)

      refute_receive :second_ran, 400
    end
  end
end
