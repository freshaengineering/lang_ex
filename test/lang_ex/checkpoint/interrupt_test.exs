defmodule LangEx.Checkpoint.InterruptTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph
  alias LangEx.Command

  describe "interrupts and resume" do
    test "interrupt pauses execution and resume continues it" do
      graph =
        Graph.new(value: 0, approved: false)
        |> Graph.add_node(:check, fn state ->
          approval = LangEx.Interrupt.interrupt("Approve value #{state.value}?")
          %{approved: approval}
        end)
        |> Graph.add_node(:finalize, fn state -> %{value: state.value * 10} end)
        |> Graph.add_edge(:__start__, :check)
        |> Graph.add_edge(:check, :finalize)
        |> Graph.add_edge(:finalize, :__end__)
        |> Graph.compile(checkpointer: LangEx.Checkpointer.Memory)

      {:interrupt, "Approve value 42?", paused_state} =
        LangEx.invoke(graph, %{value: 42}, config: [thread_id: "test-interrupt-1"])

      assert %{value: 42, approved: false} = paused_state

      {:ok, result} =
        LangEx.invoke(graph, %Command{resume: true}, config: [thread_id: "test-interrupt-1"])

      assert %{approved: true, value: 420} = result
    end

    test "interrupt without checkpointer returns interrupt tuple" do
      graph =
        Graph.new(x: 0)
        |> Graph.add_node(:pause, fn _state ->
          LangEx.Interrupt.interrupt("waiting")
          %{x: 1}
        end)
        |> Graph.add_edge(:__start__, :pause)
        |> Graph.add_edge(:pause, :__end__)
        |> Graph.compile()

      assert {:interrupt, "waiting", _} = LangEx.invoke(graph, %{})
    end

    test "a node can interrupt multiple times across resume cycles" do
      graph =
        Graph.new(name: nil, age: nil)
        |> Graph.add_node(:collect, fn _state ->
          name = LangEx.Interrupt.interrupt("What is your name?")
          age = LangEx.Interrupt.interrupt("What is your age?")
          %{name: name, age: age}
        end)
        |> Graph.add_edge(:__start__, :collect)
        |> Graph.add_edge(:collect, :__end__)
        |> Graph.compile(checkpointer: LangEx.Checkpointer.Memory)

      config = [thread_id: "multi-interrupt-1"]

      {:interrupt, "What is your name?", _} = LangEx.invoke(graph, %{}, config: config)

      {:interrupt, "What is your age?", _} =
        LangEx.invoke(graph, %Command{resume: "Ada"}, config: config)

      {:ok, result} = LangEx.invoke(graph, %Command{resume: 36}, config: config)

      assert %{name: "Ada", age: 36} = result
    end

    test "resume accepts a map of interrupt ids to values" do
      graph =
        Graph.new(name: nil, age: nil)
        |> Graph.add_node(:collect, fn _state ->
          name = LangEx.Interrupt.interrupt("name?")
          age = LangEx.Interrupt.interrupt("age?")
          %{name: name, age: age}
        end)
        |> Graph.add_edge(:__start__, :collect)
        |> Graph.add_edge(:collect, :__end__)
        |> Graph.compile(checkpointer: LangEx.Checkpointer.Memory)

      config = [thread_id: "multi-interrupt-2"]

      {:interrupt, "name?", _} = LangEx.invoke(graph, %{}, config: config)

      {:ok, result} =
        LangEx.invoke(graph, %Command{resume: %{"collect:0" => "Ada", "collect:1" => 36}},
          config: config
        )

      assert %{name: "Ada", age: 36} = result
    end

    test "a Send target that interrupts resumes with its Send payload" do
      graph =
        Graph.new(results: {[], &Kernel.++/2})
        |> Graph.add_node(:setup, fn _state -> %{} end)
        |> Graph.add_node(:worker, fn state ->
          answer = LangEx.Interrupt.interrupt("process #{state.item}?")
          %{results: [{state.item, answer}]}
        end)
        |> Graph.add_edge(:__start__, :setup)
        |> Graph.add_conditional_edges(:setup, fn _state ->
          [%LangEx.Send{node: :worker, state: %{item: "a"}}]
        end)
        |> Graph.add_edge(:worker, :__end__)
        |> Graph.compile(checkpointer: LangEx.Checkpointer.Memory)

      config = [thread_id: "send-interrupt-1"]

      {:interrupt, "process a?", _} = LangEx.invoke(graph, %{}, config: config)

      {:ok, result} = LangEx.invoke(graph, %Command{resume: :approved}, config: config)

      assert %{results: [{"a", :approved}]} = result
    end

    test "completed siblings' distinct next targets survive an interrupt" do
      graph =
        Graph.new(trail: {[], &Kernel.++/2}, approved: nil)
        |> Graph.add_node(:fanout, fn _state -> %{} end)
        |> Graph.add_node(:fast, fn _state -> %{trail: [:fast]} end)
        |> Graph.add_node(:fast_next, fn _state -> %{trail: [:fast_next]} end)
        |> Graph.add_node(:slow, fn _state ->
          %{approved: LangEx.Interrupt.interrupt("approve?")}
        end)
        |> Graph.add_edge(:__start__, :fanout)
        |> Graph.add_edge(:fanout, :fast)
        |> Graph.add_edge(:fanout, :slow)
        |> Graph.add_edge(:fast, :fast_next)
        |> Graph.add_edge(:fast_next, :__end__)
        |> Graph.add_edge(:slow, :__end__)
        |> Graph.compile(checkpointer: LangEx.Checkpointer.Memory)

      config = [thread_id: "sibling-edges-1"]

      {:interrupt, "approve?", _} = LangEx.invoke(graph, %{}, config: config)

      {:ok, result} = LangEx.invoke(graph, %Command{resume: true}, config: config)

      assert %{approved: true, trail: [:fast, :fast_next]} = result
    end

    test "a deferred fan-in node survives a sibling interrupt" do
      {:ok, joins} = Agent.start_link(fn -> 0 end)

      graph =
        Graph.new(hits: {[], &Kernel.++/2}, approved: nil, summary: nil)
        |> Graph.add_node(:fan, fn _state -> %{} end)
        |> Graph.add_node(:short, fn _state -> %{hits: [:short]} end)
        |> Graph.add_node(:long_a, fn _state -> %{hits: [:long_a]} end)
        |> Graph.add_node(:long_b, fn _state ->
          %{approved: LangEx.Interrupt.interrupt("proceed?"), hits: [:long_b]}
        end)
        |> Graph.add_node(
          :join,
          fn state ->
            Agent.update(joins, &(&1 + 1))
            %{summary: state.hits |> Enum.sort() |> Enum.join(",")}
          end,
          defer: true
        )
        |> Graph.add_edge(:__start__, :fan)
        |> Graph.add_edge(:fan, :short)
        |> Graph.add_edge(:fan, :long_a)
        |> Graph.add_edge(:long_a, :long_b)
        |> Graph.add_edge(:short, :join)
        |> Graph.add_edge(:long_b, :join)
        |> Graph.add_edge(:join, :__end__)
        |> Graph.compile(checkpointer: LangEx.Checkpointer.Memory)

      config = [thread_id: "deferred-interrupt-1"]

      {:interrupt, "proceed?", _} = LangEx.invoke(graph, %{}, config: config)

      {:ok, result} = LangEx.invoke(graph, %Command{resume: true}, config: config)

      assert %{summary: "long_a,long_b,short"} = result
      assert Agent.get(joins, & &1) == 1
    end

    test "parallel sibling results survive an interrupt" do
      graph =
        Graph.new(fast_done: false, approved: nil, total: 0)
        |> Graph.add_node(:fanout, fn _state -> %{} end)
        |> Graph.add_node(:fast, fn _state -> %{fast_done: true} end)
        |> Graph.add_node(:slow, fn _state ->
          approval = LangEx.Interrupt.interrupt("approve?")
          %{approved: approval}
        end)
        |> Graph.add_node(:join, fn state ->
          %{total: boolean_count([state.fast_done, state.approved])}
        end)
        |> Graph.add_edge(:__start__, :fanout)
        |> Graph.add_edge(:fanout, :fast)
        |> Graph.add_edge(:fanout, :slow)
        |> Graph.add_edge(:fast, :join)
        |> Graph.add_edge(:slow, :join)
        |> Graph.add_edge(:join, :__end__)
        |> Graph.compile(checkpointer: LangEx.Checkpointer.Memory)

      config = [thread_id: "parallel-interrupt-1"]

      {:interrupt, "approve?", paused} = LangEx.invoke(graph, %{}, config: config)

      assert %{fast_done: true} = paused

      {:ok, result} = LangEx.invoke(graph, %Command{resume: true}, config: config)

      assert %{fast_done: true, approved: true, total: 2} = result
    end
  end

  describe "static breakpoints" do
    test "interrupt_before pauses ahead of the node and resume runs it" do
      graph =
        Graph.new(log: {[], &Kernel.++/2})
        |> Graph.add_node(:first, fn _state -> %{log: [:first]} end)
        |> Graph.add_node(:second, fn _state -> %{log: [:second]} end)
        |> Graph.add_edge(:__start__, :first)
        |> Graph.add_edge(:first, :second)
        |> Graph.add_edge(:second, :__end__)
        |> Graph.compile(checkpointer: LangEx.Checkpointer.Memory, interrupt_before: [:second])

      config = [thread_id: "static-before-1"]

      {:interrupt, {:interrupt_before, :second}, paused} =
        LangEx.invoke(graph, %{}, config: config)

      assert %{log: [:first]} = paused

      {:ok, result} = LangEx.invoke(graph, %Command{resume: true}, config: config)

      assert %{log: [:first, :second]} = result
    end

    test "a dynamic interrupt behind interrupt_before resolves across resumes" do
      graph =
        Graph.new(approved: nil)
        |> Graph.add_node(:gate, fn _state ->
          %{approved: LangEx.Interrupt.interrupt("really?")}
        end)
        |> Graph.add_edge(:__start__, :gate)
        |> Graph.add_edge(:gate, :__end__)
        |> Graph.compile(checkpointer: LangEx.Checkpointer.Memory, interrupt_before: [:gate])

      config = [thread_id: "static-dynamic-1"]

      {:interrupt, {:interrupt_before, :gate}, _} = LangEx.invoke(graph, %{}, config: config)

      {:interrupt, "really?", _} =
        LangEx.invoke(graph, %Command{resume: true}, config: config)

      {:ok, result} = LangEx.invoke(graph, %Command{resume: :confirmed}, config: config)

      assert %{approved: :confirmed} = result
    end

    test "interrupt_after pauses once the node has run" do
      graph =
        Graph.new(log: {[], &Kernel.++/2})
        |> Graph.add_node(:first, fn _state -> %{log: [:first]} end)
        |> Graph.add_node(:second, fn _state -> %{log: [:second]} end)
        |> Graph.add_edge(:__start__, :first)
        |> Graph.add_edge(:first, :second)
        |> Graph.add_edge(:second, :__end__)
        |> Graph.compile(checkpointer: LangEx.Checkpointer.Memory, interrupt_after: [:first])

      config = [thread_id: "static-after-1"]

      {:interrupt, {:interrupt_after, :first}, paused} =
        LangEx.invoke(graph, %{}, config: config)

      assert %{log: [:first]} = paused

      {:ok, result} = LangEx.invoke(graph, %Command{resume: true}, config: config)

      assert %{log: [:first, :second]} = result
    end
  end

  defp boolean_count(values), do: Enum.count(values, &(&1 == true))
end
