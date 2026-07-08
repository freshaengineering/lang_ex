defmodule LangEx.Checkpoint.StateApiTest do
  use ExUnit.Case, async: false

  alias LangEx.Checkpoint
  alias LangEx.Checkpointer.Mock
  alias LangEx.Graph

  setup do
    Mock.clear()
    {:ok, graph: build_graph()}
  end

  describe "get_state/2" do
    test "returns the latest checkpoint after a run", %{graph: graph} do
      {:ok, _} = LangEx.invoke(graph, %{value: 1}, config: [thread_id: "st-1"])

      assert {:ok, %Checkpoint{thread_id: "st-1", state: %{value: 2}}} =
               LangEx.get_state(graph, config: [thread_id: "st-1"])
    end

    test "loads a specific checkpoint by id", %{graph: graph} do
      {:ok, _} = LangEx.invoke(graph, %{value: 1}, config: [thread_id: "st-2"])

      [_latest, older | _] = LangEx.get_state_history(graph, config: [thread_id: "st-2"])

      assert {:ok, %Checkpoint{checkpoint_id: id}} =
               LangEx.get_state(graph,
                 config: [thread_id: "st-2", checkpoint_id: older.checkpoint_id]
               )

      assert id == older.checkpoint_id
    end

    test "returns :none for unknown thread", %{graph: graph} do
      assert :none = LangEx.get_state(graph, config: [thread_id: "missing"])
    end
  end

  describe "get_state_history/2" do
    test "returns checkpoints most recent first with parent lineage", %{graph: graph} do
      {:ok, _} = LangEx.invoke(graph, %{value: 1}, config: [thread_id: "hist-1"])

      history = LangEx.get_state_history(graph, config: [thread_id: "hist-1"])

      assert [%Checkpoint{parent_id: parent}, %Checkpoint{checkpoint_id: parent, parent_id: nil}] =
               history
    end
  end

  describe "update_state/3" do
    test "saves a forked checkpoint with the update applied via reducers", %{graph: graph} do
      {:ok, _} = LangEx.invoke(graph, %{value: 1}, config: [thread_id: "upd-1"])

      {:ok, %Checkpoint{checkpoint_id: latest_id}} =
        LangEx.get_state(graph, config: [thread_id: "upd-1"])

      assert {:ok, %Checkpoint{parent_id: ^latest_id, state: %{value: 99}}} =
               LangEx.update_state(graph, %{value: 99}, config: [thread_id: "upd-1"])

      assert {:ok, %Checkpoint{parent_id: ^latest_id}} =
               LangEx.get_state(graph, config: [thread_id: "upd-1"])
    end

    test "returns an error when there is no checkpoint to update", %{graph: graph} do
      assert {:error, :no_checkpoint} =
               LangEx.update_state(graph, %{value: 1}, config: [thread_id: "nope"])
    end
  end

  defp build_graph do
    Graph.new(value: 0)
    |> Graph.add_node(:first, fn state -> %{value: state.value + 1} end)
    |> Graph.add_node(:second, fn state -> %{value: state.value} end)
    |> Graph.add_edge(:__start__, :first)
    |> Graph.add_edge(:first, :second)
    |> Graph.add_edge(:second, :__end__)
    |> Graph.compile(checkpointer: Mock)
  end
end
