defmodule LangEx.Checkpoint.CheckpointStateTest do
  use ExUnit.Case, async: false

  alias LangEx.Checkpointer.Mock
  alias LangEx.Graph

  setup do
    Mock.clear()
    :ok
  end

  describe "invoke with existing checkpoint merges new input" do
    test "new input overrides checkpointed values (last-write-wins)" do
      graph =
        Graph.new(value: 0, label: "")
        |> Graph.add_node(:passthrough, fn state -> %{label: "done:#{state.value}"} end)
        |> Graph.add_edge(:__start__, :passthrough)
        |> Graph.add_edge(:passthrough, :__end__)
        |> Graph.compile(checkpointer: Mock)

      {:ok, first} =
        LangEx.invoke(graph, %{value: 1}, config: [thread_id: "merge-test-1"])

      assert %{value: 1, label: "done:1"} = first

      {:ok, second} =
        LangEx.invoke(graph, %{value: 99}, config: [thread_id: "merge-test-1"])

      assert %{value: 99, label: "done:99"} = second
    end

    test "checkpointed state is preserved for keys not in new input" do
      graph =
        Graph.new(a: 0, b: 0)
        |> Graph.add_node(:sum, fn state -> %{b: state.a + state.b} end)
        |> Graph.add_edge(:__start__, :sum)
        |> Graph.add_edge(:sum, :__end__)
        |> Graph.compile(checkpointer: Mock)

      {:ok, first} =
        LangEx.invoke(graph, %{a: 10, b: 5}, config: [thread_id: "merge-test-2"])

      assert %{a: 10, b: 15} = first

      {:ok, second} =
        LangEx.invoke(graph, %{a: 20}, config: [thread_id: "merge-test-2"])

      assert %{a: 20, b: 35} = second
    end

    test "reducers are applied when merging input into checkpoint" do
      graph =
        Graph.new(log: {[], &Kernel.++/2}, step: 0)
        |> Graph.add_node(:work, fn state ->
          %{log: ["step_#{state.step}"], step: state.step + 1}
        end)
        |> Graph.add_edge(:__start__, :work)
        |> Graph.add_edge(:work, :__end__)
        |> Graph.compile(checkpointer: Mock)

      {:ok, first} =
        LangEx.invoke(graph, %{log: ["init"]}, config: [thread_id: "merge-test-3"])

      assert %{log: ["init", "step_0"], step: 1} = first

      {:ok, second} =
        LangEx.invoke(graph, %{log: ["resumed"]}, config: [thread_id: "merge-test-3"])

      assert %{log: ["init", "step_0", "resumed", "step_1"], step: 2} = second
    end

    test "fresh thread without checkpoint applies input to schema defaults" do
      graph =
        Graph.new(value: 0, label: "default")
        |> Graph.add_node(:read, fn state -> %{label: "saw:#{state.value}"} end)
        |> Graph.add_edge(:__start__, :read)
        |> Graph.add_edge(:read, :__end__)
        |> Graph.compile(checkpointer: Mock)

      {:ok, result} =
        LangEx.invoke(graph, %{value: 42}, config: [thread_id: "fresh-thread"])

      assert %{value: 42, label: "saw:42"} = result
    end

    test "empty input resumes a crashed run from the pending nodes" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      graph =
        Graph.new(trail: {[], &Kernel.++/2})
        |> Graph.add_node(:prepare, fn _state -> %{trail: [:prepare]} end)
        |> Graph.add_node(:flaky, fn _state ->
          Agent.get_and_update(attempts, &{&1, &1 + 1})
          |> Kernel.==(0)
          |> crash_first_attempt()
        end)
        |> Graph.add_edge(:__start__, :prepare)
        |> Graph.add_edge(:prepare, :flaky)
        |> Graph.add_edge(:flaky, :__end__)
        |> Graph.compile(checkpointer: Mock)

      assert_raise RuntimeError, "transient failure", fn ->
        LangEx.invoke(graph, %{trail: [:input]}, config: [thread_id: "crash-recovery"])
      end

      {:ok, result} = LangEx.invoke(graph, %{}, config: [thread_id: "crash-recovery"])

      assert %{trail: [:input, :prepare, :flaky]} = result
    end

    test "empty input on a completed thread starts a fresh pass" do
      graph =
        Graph.new(runs: {0, &Kernel.+/2})
        |> Graph.add_node(:work, fn _state -> %{runs: 1} end)
        |> Graph.add_edge(:__start__, :work)
        |> Graph.add_edge(:work, :__end__)
        |> Graph.compile(checkpointer: Mock)

      {:ok, %{runs: 1}} = LangEx.invoke(graph, %{}, config: [thread_id: "completed-thread"])
      {:ok, result} = LangEx.invoke(graph, %{}, config: [thread_id: "completed-thread"])

      assert %{runs: 2} = result
    end

    test "without checkpointer, input always applies to schema defaults" do
      graph =
        Graph.new(value: 0)
        |> Graph.add_node(:double, fn state -> %{value: state.value * 2} end)
        |> Graph.add_edge(:__start__, :double)
        |> Graph.add_edge(:double, :__end__)
        |> Graph.compile()

      {:ok, _} = LangEx.invoke(graph, %{value: 5})
      {:ok, result} = LangEx.invoke(graph, %{value: 7})

      assert %{value: 14} = result
    end
  end

  defp crash_first_attempt(true), do: raise("transient failure")
  defp crash_first_attempt(false), do: %{trail: [:flaky]}
end
