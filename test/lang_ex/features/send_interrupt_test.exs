defmodule LangEx.Features.SendInterruptTest do
  use ExUnit.Case, async: false

  alias LangEx.Checkpointer.Memory
  alias LangEx.Command
  alias LangEx.Graph
  alias LangEx.Interrupt
  alias LangEx.Send

  setup do
    Memory.clear()
    :ok
  end

  defp fan_out_graph(payloads) do
    Graph.new(seen: {[], fn acc, new -> acc ++ new end})
    |> Graph.add_node(:fan, fn _state ->
      %Command{goto: Enum.map(payloads, &%Send{node: :worker, state: %{item: &1}})}
    end)
    |> Graph.add_node(:worker, fn state ->
      %{seen: [{state.item, Interrupt.interrupt({:approve, state.item})}]}
    end)
    |> Graph.add_edge(:__start__, :fan)
    |> Graph.add_edge(:worker, :__end__)
    |> Graph.compile(checkpointer: Memory, warn_unreachable: false)
  end

  test "each fan-out branch gets its own interrupt id" do
    graph = fan_out_graph([1, 2, 3])
    config = [thread_id: "fan-distinct"]

    {:interrupt, pending, _state} = LangEx.invoke(graph, %{}, config: config)

    assert length(pending) == 3
    assert length(Enum.uniq(Enum.map(pending, & &1.id))) == 3
    assert Enum.all?(pending, &String.starts_with?(&1.id, "worker#"))
  end

  test "identical payloads stay separately addressable" do
    graph = fan_out_graph([:same, :same])
    config = [thread_id: "fan-identical"]

    {:interrupt, pending, _state} = LangEx.invoke(graph, %{}, config: config)

    assert length(Enum.uniq(Enum.map(pending, & &1.id))) == 2
  end

  test "branches resume independently with per-id values" do
    graph = fan_out_graph([1, 2])
    config = [thread_id: "fan-resume"]

    {:interrupt, pending, _state} = LangEx.invoke(graph, %{}, config: config)

    answers =
      Map.new(pending, fn %{id: id, value: {:approve, item}} -> {id, {:decided, item * 10}} end)

    assert {:ok, %{seen: seen}} =
             LangEx.invoke(graph, %Command{resume: answers}, config: config)

    assert Enum.sort(seen) == [{1, {:decided, 10}}, {2, {:decided, 20}}]
  end

  test "answering one branch leaves the other pending" do
    graph = fan_out_graph([1, 2])
    config = [thread_id: "fan-partial"]

    {:interrupt, pending, _state} = LangEx.invoke(graph, %{}, config: config)
    [first, second] = Enum.sort_by(pending, fn %{value: {:approve, item}} -> item end)

    # A single remaining interrupt surfaces its bare payload, so the
    # branch identity is read back from the checkpoint.
    assert {:interrupt, {:approve, 2}, _state} =
             LangEx.invoke(graph, %Command{resume: %{first.id => :ok}}, config: config)

    assert {:ok, %{pending_interrupts: [%{id: still_pending}]}} =
             LangEx.get_state(graph, config: config)

    assert still_pending == second.id
  end

  test "a plain node keeps its unprefixed interrupt id" do
    graph =
      Graph.new(answer: nil)
      |> Graph.add_node(:ask, fn _state -> %{answer: Interrupt.interrupt(:question)} end)
      |> Graph.add_edge(:__start__, :ask)
      |> Graph.add_edge(:ask, :__end__)
      |> Graph.compile(checkpointer: Memory)

    config = [thread_id: "plain-node"]

    assert {:interrupt, :question, _state} = LangEx.invoke(graph, %{}, config: config)
    assert {:ok, %{answer: 42}} = LangEx.invoke(graph, %Command{resume: 42}, config: config)
  end
end
