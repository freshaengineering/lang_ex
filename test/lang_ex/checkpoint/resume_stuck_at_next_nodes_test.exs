defmodule LangEx.Checkpoint.ResumeStuckAtNextNodesTest do
  @moduledoc """
  Regression test for the case where a graph stops mid-execution at a
  non-interrupt node. The latest checkpoint has `next_nodes` queued but
  `pending_interrupts: nil`. A subsequent `LangEx.invoke(graph, %Command{resume: _})`
  used to return `{:error, :no_pending_interrupt}` and leave the graph
  permanently stuck. With the fix, it recovers by continuing execution
  from the queued nodes (the resume value is discarded — there's no
  interrupt to feed it to).
  """

  use ExUnit.Case, async: false

  alias LangEx.Checkpoint
  alias LangEx.Checkpointer.Mock
  alias LangEx.Command
  alias LangEx.Graph

  setup do
    Mock.clear()
    :ok
  end

  test "resume continues from queued next_nodes when no pending interrupt exists anywhere" do
    graph =
      Graph.new(value: 0, ran_a: false, ran_b: false)
      |> Graph.add_node(:a, fn state -> %{ran_a: true, value: state.value + 1} end)
      |> Graph.add_node(:b, fn state -> %{ran_b: true, value: state.value * 10} end)
      |> Graph.add_edge(:__start__, :a)
      |> Graph.add_edge(:a, :b)
      |> Graph.add_edge(:b, :__end__)
      |> Graph.compile(checkpointer: Mock)

    thread_id = "test-stuck-next-nodes-1"
    config = [thread_id: thread_id]

    # Simulate a stuck checkpoint: graph stopped mid-execution after queuing :a
    # but before :a ran. No pending interrupts anywhere in history.
    stuck_checkpoint =
      Checkpoint.new(
        thread_id: thread_id,
        state: %{value: 5, ran_a: false, ran_b: false},
        next_nodes: [:a],
        step: 1,
        metadata: %{},
        pending_interrupts: nil
      )

    :ok = Mock.save(config, stuck_checkpoint)

    # The fix: resume should continue from :a, run a -> b -> end, instead of
    # returning {:error, :no_pending_interrupt}.
    assert {:ok, final_state} =
             LangEx.invoke(graph, %Command{resume: :nudge}, config: config)

    assert final_state.ran_a === true
    assert final_state.ran_b === true
    assert final_state.value === 60
  end

  test "still returns {:error, :no_pending_interrupt} when next_nodes is empty and no interrupts exist" do
    graph =
      Graph.new(x: 0)
      |> Graph.add_node(:noop, fn state -> state end)
      |> Graph.add_edge(:__start__, :noop)
      |> Graph.add_edge(:noop, :__end__)
      |> Graph.compile(checkpointer: Mock)

    thread_id = "test-stuck-empty-next-nodes-1"
    config = [thread_id: thread_id]

    empty_checkpoint =
      Checkpoint.new(
        thread_id: thread_id,
        state: %{x: 1},
        next_nodes: [],
        step: 1,
        metadata: %{},
        pending_interrupts: nil
      )

    :ok = Mock.save(config, empty_checkpoint)

    assert {:error, :no_pending_interrupt} =
             LangEx.invoke(graph, %Command{resume: :nudge}, config: config)
  end

  test "still returns {:error, :no_pending_interrupt} when next_nodes only has :__end__" do
    graph =
      Graph.new(x: 0)
      |> Graph.add_node(:noop, fn state -> state end)
      |> Graph.add_edge(:__start__, :noop)
      |> Graph.add_edge(:noop, :__end__)
      |> Graph.compile(checkpointer: Mock)

    thread_id = "test-stuck-end-next-nodes-1"
    config = [thread_id: thread_id]

    end_checkpoint =
      Checkpoint.new(
        thread_id: thread_id,
        state: %{x: 1},
        next_nodes: [:__end__],
        step: 1,
        metadata: %{},
        pending_interrupts: nil
      )

    :ok = Mock.save(config, end_checkpoint)

    assert {:error, :no_pending_interrupt} =
             LangEx.invoke(graph, %Command{resume: :nudge}, config: config)
  end
end
