defmodule LangEx.Checkpoint.DurabilityTest do
  use ExUnit.Case, async: false

  alias LangEx.Checkpoint
  alias LangEx.Checkpointer.Memory
  alias LangEx.Command
  alias LangEx.Graph
  alias LangEx.Interrupt

  setup do
    Memory.clear()
    :ok
  end

  defp counting_graph do
    Graph.new(value: 0)
    |> Graph.add_node(:first, fn state -> %{value: state.value + 1} end)
    |> Graph.add_node(:second, fn state -> %{value: state.value + 1} end)
    |> Graph.add_edge(:__start__, :first)
    |> Graph.add_edge(:first, :second)
    |> Graph.add_edge(:second, :__end__)
    |> Graph.compile(checkpointer: Memory)
  end

  defp graph_with_subgraph do
    inner =
      Graph.new(value: 0, note: nil)
      |> Graph.add_node(:inner_work, fn state -> %{value: state.value + 10} end)
      |> Graph.add_edge(:__start__, :inner_work)
      |> Graph.add_edge(:inner_work, :__end__)
      |> Graph.compile(checkpointer: Memory)

    Graph.new(value: 0, note: nil)
    |> Graph.add_node(:planner, inner)
    |> Graph.add_edge(:__start__, :planner)
    |> Graph.add_edge(:planner, :__end__)
    |> Graph.compile(checkpointer: Memory)
  end

  describe "subgraph namespaces" do
    test "a subgraph checkpoints under the parent's thread" do
      graph = graph_with_subgraph()
      config = [thread_id: "ns-1"]

      {:ok, %{value: 10}} = LangEx.invoke(graph, %{value: 0}, config: config)

      assert {:ok, %Checkpoint{checkpoint_ns: ""}} = LangEx.get_state(graph, config: config)

      assert {:ok, %Checkpoint{thread_id: "ns-1", checkpoint_ns: "planner"}} =
               LangEx.get_state(graph, config: config ++ [checkpoint_ns: "planner"])
    end

    test "deleting a thread removes its subgraph checkpoints too" do
      graph = graph_with_subgraph()
      config = [thread_id: "ns-delete"]

      {:ok, _} = LangEx.invoke(graph, %{value: 0}, config: config)
      :ok = LangEx.delete_thread(graph, config: config)

      assert :none = LangEx.get_state(graph, config: config)
      assert :none = LangEx.get_state(graph, config: config ++ [checkpoint_ns: "planner"])
    end

    test "a subgraph records its parent's checkpoint for lineage" do
      graph = graph_with_subgraph()
      config = [thread_id: "ns-lineage"]

      {:ok, _} = LangEx.invoke(graph, %{value: 0}, config: config)

      assert {:ok, %Checkpoint{metadata: %{parents: %{"" => parent_id}}}} =
               LangEx.get_state(graph, config: config ++ [checkpoint_ns: "planner"])

      assert Enum.any?(
               LangEx.get_state_history(graph, config: config),
               &(&1.checkpoint_id == parent_id)
             )
    end
  end

  describe "provenance" do
    test "each write records why it exists" do
      graph = counting_graph()
      config = [thread_id: "prov-1"]

      {:ok, _} = LangEx.invoke(graph, %{value: 1}, config: config)
      {:ok, _} = LangEx.update_state(graph, %{value: 50}, config: config)

      [oldest | _] =
        graph
        |> LangEx.get_state_history(config: config)
        |> Enum.reverse()

      assert %Checkpoint{source: :input} = oldest

      assert [%Checkpoint{source: :update}] =
               LangEx.get_state_history(graph, config: config, source: :update)
    end

    test "updating a pinned historical checkpoint is recorded as a fork" do
      graph = counting_graph()
      config = [thread_id: "prov-fork"]

      {:ok, _} = LangEx.invoke(graph, %{value: 1}, config: config)
      [_latest, older | _] = LangEx.get_state_history(graph, config: config)

      assert {:ok, %Checkpoint{source: :fork}} =
               LangEx.update_state(graph, %{value: 7},
                 config: config ++ [checkpoint_id: older.checkpoint_id]
               )
    end
  end

  describe "copy_thread/3" do
    test "the copy resumes independently of its source" do
      graph =
        Graph.new(value: 0, answer: nil)
        |> Graph.add_node(:ask, fn _state -> %{answer: Interrupt.interrupt(:pick)} end)
        |> Graph.add_edge(:__start__, :ask)
        |> Graph.add_edge(:ask, :__end__)
        |> Graph.compile(checkpointer: Memory)

      source = [thread_id: "copy-src"]
      branch = [thread_id: "copy-branch"]

      {:interrupt, :pick, _} = LangEx.invoke(graph, %{value: 1}, config: source)
      :ok = LangEx.copy_thread(graph, "copy-branch", config: source)

      assert {:ok, %{answer: :left}} =
               LangEx.invoke(graph, %Command{resume: :left}, config: source)

      assert {:ok, %{answer: :right}} =
               LangEx.invoke(graph, %Command{resume: :right}, config: branch)
    end

    test "subgraph namespaces come along with the copy" do
      graph = graph_with_subgraph()

      {:ok, _} = LangEx.invoke(graph, %{value: 0}, config: [thread_id: "copy-ns"])
      :ok = LangEx.copy_thread(graph, "copy-ns-2", config: [thread_id: "copy-ns"])

      assert {:ok, %Checkpoint{thread_id: "copy-ns-2", checkpoint_ns: "planner"}} =
               LangEx.get_state(graph, config: [thread_id: "copy-ns-2", checkpoint_ns: "planner"])
    end
  end

  describe "per-task durability" do
    test "recovering a crashed super-step does not re-run completed work" do
      test_pid = self()

      graph =
        Graph.new(done: {[], fn acc, new -> acc ++ new end})
        |> Graph.add_node(:enter, fn _state -> %{} end)
        |> Graph.add_node(:slow, fn _state ->
          send(test_pid, :slow_ran)
          %{done: [:slow]}
        end)
        |> Graph.add_node(:boom, fn _state ->
          send(test_pid, :boom_ran)
          crash_once(test_pid)
        end)
        |> Graph.add_edge(:__start__, :enter)
        |> Graph.add_edge(:enter, :slow)
        |> Graph.add_edge(:enter, :boom)
        |> Graph.add_edge(:slow, :__end__)
        |> Graph.add_edge(:boom, :__end__)
        |> Graph.compile(checkpointer: Memory, warn_unreachable: false)

      config = [thread_id: "journal-1"]

      assert {:error, _} = LangEx.invoke(graph, %{}, config: config)
      assert_received :slow_ran
      assert_received :boom_ran

      # The retry re-runs only the node that failed; :slow is replayed
      # from the journal rather than executed a second time.
      assert {:ok, %{done: done}} = LangEx.invoke(graph, %{}, config: config)
      assert Enum.sort(done) == [:boom, :slow]

      refute_received :slow_ran
      assert_received :boom_ran
    end

    test "a fresh run never replays a journal left by an abandoned one" do
      test_pid = self()

      graph =
        Graph.new(runs: {0, fn acc, new -> acc + new end})
        |> Graph.add_node(:work, fn _state ->
          send(test_pid, :work_ran)
          %{runs: 1}
        end)
        |> Graph.add_edge(:__start__, :work)
        |> Graph.add_edge(:work, :__end__)
        |> Graph.compile(checkpointer: Memory)

      config = [thread_id: "journal-fresh"]

      {:ok, %{runs: 1}} = LangEx.invoke(graph, %{}, config: config)
      assert_received :work_ran

      # Non-empty input starts a new pass, which must execute the node.
      {:ok, %{runs: 2}} = LangEx.invoke(graph, %{runs: 0}, config: config)
      assert_received :work_ran
    end
  end

  # Fails on its first invocation for a given test process, succeeds after.
  defp crash_once(test_pid) do
    key = {__MODULE__, test_pid}

    :persistent_term.get(key, :pending)
    |> case do
      :pending ->
        :persistent_term.put(key, :done)
        raise "boom"

      :done ->
        :persistent_term.erase(key)
        %{done: [:boom]}
    end
  end
end
