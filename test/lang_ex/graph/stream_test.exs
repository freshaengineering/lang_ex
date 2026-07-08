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

    test ":values mode yields full state after each step" do
      events =
        Graph.new(value: 0)
        |> Graph.add_node(:inc, fn state -> %{value: state.value + 1} end)
        |> Graph.add_node(:double, fn state -> %{value: state.value * 2} end)
        |> Graph.add_edge(:__start__, :inc)
        |> Graph.add_edge(:inc, :double)
        |> Graph.add_edge(:double, :__end__)
        |> Graph.compile()
        |> LangEx.stream(%{value: 1}, modes: [:values])
        |> Enum.to_list()

      assert [
               {:values, %{value: 2}},
               {:values, %{value: 4}},
               {:done, {:ok, %{value: 4}}}
             ] = events
    end

    test ":custom mode yields events emitted from inside nodes" do
      events =
        Graph.new(value: 0)
        |> Graph.add_node(:work, fn state ->
          LangEx.Graph.Stream.emit({:progress, 50})
          LangEx.Graph.Stream.emit({:progress, 100})
          %{value: state.value + 1}
        end)
        |> Graph.add_edge(:__start__, :work)
        |> Graph.add_edge(:work, :__end__)
        |> Graph.compile()
        |> LangEx.stream(%{value: 0}, modes: [:custom])
        |> Enum.to_list()

      assert [
               {:custom, {:progress, 50}},
               {:custom, {:progress, 100}},
               {:done, {:ok, %{value: 1}}}
             ] = events
    end

    test ":messages mode yields token deltas from streaming providers" do
      events =
        Graph.new(text: "")
        |> Graph.add_node(:llm, fn _state ->
          # Simulates what ChatModel does when an adapter streams tokens.
          LangEx.Graph.Stream.notify({:message_delta, %{node: :llm, kind: :content, text: "Hel"}})
          LangEx.Graph.Stream.notify({:message_delta, %{node: :llm, kind: :content, text: "lo"}})
          %{text: "Hello"}
        end)
        |> Graph.add_edge(:__start__, :llm)
        |> Graph.add_edge(:llm, :__end__)
        |> Graph.compile()
        |> LangEx.stream(%{}, modes: [:messages])
        |> Enum.to_list()

      assert [
               {:message_delta, %{text: "Hel"}},
               {:message_delta, %{text: "lo"}},
               {:done, {:ok, _}}
             ] = events
    end

    test "interrupts are always delivered and Command resumes a stream" do
      graph =
        Graph.new(approved: nil)
        |> Graph.add_node(:check, fn _state ->
          %{approved: LangEx.Interrupt.interrupt("approve?")}
        end)
        |> Graph.add_edge(:__start__, :check)
        |> Graph.add_edge(:check, :__end__)
        |> Graph.compile(checkpointer: LangEx.Checkpointer.Mock)

      config = [thread_id: "stream-resume-1"]

      paused = graph |> LangEx.stream(%{}, config: config, modes: [:values]) |> Enum.to_list()

      assert Enum.any?(paused, &match?({:interrupt, "approve?"}, &1))
      assert List.last(paused) == {:done, {:interrupt, "approve?", %{approved: nil}}}

      resumed =
        graph
        |> LangEx.stream(%LangEx.Command{resume: true}, config: config)
        |> Enum.to_list()

      assert List.last(resumed) == {:done, {:ok, %{approved: true}}}
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
