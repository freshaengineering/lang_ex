defmodule LangEx.Graph.EnginePoliciesTest do
  use ExUnit.Case, async: false

  alias LangEx.Checkpointer.Memory
  alias LangEx.Command
  alias LangEx.Graph
  alias LangEx.Graph.NodeCache
  alias LangEx.Interrupt

  setup do
    Memory.clear()
    NodeCache.clear()
    :ok
  end

  describe "scoped fan-in barriers" do
    test "a merge node waits for the branches it names" do
      graph =
        Graph.new(order: {[], &Kernel.++/2})
        |> Graph.add_node(:split, fn _state -> %{} end)
        |> Graph.add_node(:search, fn _state -> %{order: [:search]} end)
        |> Graph.add_node(:summarize, fn _state -> %{order: [:summarize]} end)
        |> Graph.add_node(:unrelated, fn _state -> %{order: [:unrelated]} end)
        |> Graph.add_node(:merge, fn _state -> %{order: [:merge]} end,
          defer: [:search, :summarize]
        )
        |> Graph.add_edge(:__start__, :split)
        |> Graph.add_edge(:split, :search)
        |> Graph.add_edge(:split, :summarize)
        |> Graph.add_edge(:split, :unrelated)
        |> Graph.add_edge(:search, :merge)
        |> Graph.add_edge(:summarize, :merge)
        |> Graph.add_edge(:merge, :__end__)
        |> Graph.add_edge(:unrelated, :__end__)
        |> Graph.compile()

      {:ok, %{order: order}} = LangEx.invoke(graph, %{})

      assert List.last(order) == :merge
      assert Enum.sort(order) == [:merge, :search, :summarize, :unrelated]
    end

    test "a scoped barrier does not wait for nodes it did not name" do
      graph =
        Graph.new(order: {[], &Kernel.++/2})
        |> Graph.add_node(:split, fn _state -> %{} end)
        |> Graph.add_node(:slow_branch, fn _state -> %{order: [:slow_branch]} end)
        |> Graph.add_node(:quick, fn _state -> %{order: [:quick]} end, defer: [:never_runs])
        |> Graph.add_node(:never_runs, fn _state -> %{order: [:never_runs]} end)
        |> Graph.add_edge(:__start__, :split)
        |> Graph.add_edge(:split, :slow_branch)
        |> Graph.add_edge(:split, :quick)
        |> Graph.add_edge(:slow_branch, :__end__)
        |> Graph.add_edge(:quick, :__end__)
        |> Graph.add_edge(:never_runs, :__end__)
        |> Graph.compile(warn_unreachable: false)

      {:ok, %{order: order}} = LangEx.invoke(graph, %{})

      # :never_runs is never active, so the barrier never holds :quick back.
      assert Enum.sort(order) == [:quick, :slow_branch]
    end

    test "mutually barring nodes still make progress" do
      graph =
        Graph.new(order: {[], &Kernel.++/2})
        |> Graph.add_node(:split, fn _state -> %{} end)
        |> Graph.add_node(:a, fn _state -> %{order: [:a]} end, defer: [:b])
        |> Graph.add_node(:b, fn _state -> %{order: [:b]} end, defer: [:a])
        |> Graph.add_edge(:__start__, :split)
        |> Graph.add_edge(:split, :a)
        |> Graph.add_edge(:split, :b)
        |> Graph.add_edge(:a, :__end__)
        |> Graph.add_edge(:b, :__end__)
        |> Graph.compile()

      assert {:ok, %{order: order}} = LangEx.invoke(graph, %{})
      assert Enum.sort(order) == [:a, :b]
    end

    test "a non-node value in a scoped barrier is rejected at build time" do
      assert_raise ArgumentError, ~r/names the nodes it waits for/, fn ->
        Graph.new()
        |> Graph.add_node(:merge, fn _state -> %{} end, defer: ["search"])
      end
    end
  end

  describe "ephemeral state keys" do
    defp signalling_graph do
      Graph.new([hint: nil, seen: {[], &Kernel.++/2}], ephemeral: [:hint])
      |> Graph.add_node(:emit, fn _state -> %{hint: :take_shortcut} end)
      |> Graph.add_node(:read, fn state -> %{seen: [{:read, state.hint}]} end)
      |> Graph.add_node(:read_again, fn state -> %{seen: [{:read_again, state.hint}]} end)
      |> Graph.add_edge(:__start__, :emit)
      |> Graph.add_edge(:emit, :read)
      |> Graph.add_edge(:read, :read_again)
      |> Graph.add_edge(:read_again, :__end__)
      |> Graph.compile(checkpointer: Memory)
    end

    test "a signal reaches the next step and then expires" do
      {:ok, %{seen: seen, hint: hint}} =
        LangEx.invoke(signalling_graph(), %{}, config: [thread_id: "eph-1"])

      assert seen == [{:read, :take_shortcut}, {:read_again, nil}]
      assert hint == nil
    end

    test "a signal is never written to a checkpoint" do
      config = [thread_id: "eph-2"]
      {:ok, _} = LangEx.invoke(signalling_graph(), %{}, config: config)

      history = LangEx.get_state_history(signalling_graph(), config: config)

      assert Enum.all?(history, &(not Map.has_key?(&1.state, :hint)))
    end

    test "a signal does not survive a pause and resume" do
      graph =
        Graph.new([hint: nil, seen: {[], &Kernel.++/2}], ephemeral: [:hint])
        |> Graph.add_node(:emit, fn _state ->
          %{hint: :take_shortcut, seen: [Interrupt.interrupt(:confirm)]}
        end)
        |> Graph.add_node(:read, fn state -> %{seen: [{:read, state.hint}]} end)
        |> Graph.add_edge(:__start__, :emit)
        |> Graph.add_edge(:emit, :read)
        |> Graph.add_edge(:read, :__end__)
        |> Graph.compile(checkpointer: Memory)

      config = [thread_id: "eph-3"]

      {:interrupt, :confirm, _} = LangEx.invoke(graph, %{}, config: config)

      assert {:ok, %{seen: [:yes, {:read, :take_shortcut}]}} =
               LangEx.invoke(graph, %Command{resume: :yes}, config: config)
    end

    test "an undeclared ephemeral key is rejected at build time" do
      assert_raise ArgumentError, ~r/not in the state schema/, fn ->
        Graph.new([count: 0], ephemeral: [:hint])
      end
    end
  end

  describe "graph-level node defaults" do
    test "one declaration makes every node in the graph resilient" do
      test_pid = self()

      graph =
        Graph.new(attempts: {0, &(&1 + &2)})
        |> Graph.add_node(:flaky, fn _state ->
          send(test_pid, :flaky_attempt)
          fail_until(:flaky, 3)
        end)
        |> Graph.add_node(:also_flaky, fn _state ->
          send(test_pid, :also_flaky_attempt)
          fail_until(:also_flaky, 2)
        end)
        |> Graph.add_edge(:__start__, :flaky)
        |> Graph.add_edge(:flaky, :also_flaky)
        |> Graph.add_edge(:also_flaky, :__end__)
        |> Graph.compile(node_defaults: [retry: [max_attempts: 5, initial_interval_ms: 1]])

      assert {:ok, _} = LangEx.invoke(graph, %{})
      assert count_received(:flaky_attempt) == 3
      assert count_received(:also_flaky_attempt) == 2
    end

    test "a node opting out of a retry default is not retried" do
      test_pid = self()

      graph =
        Graph.new(v: 0)
        |> Graph.add_node(
          :once,
          fn _state ->
            send(test_pid, :attempt)
            raise "nope"
          end,
          retry: [max_attempts: 1]
        )
        |> Graph.add_edge(:__start__, :once)
        |> Graph.add_edge(:once, :__end__)
        |> Graph.compile(node_defaults: [retry: [max_attempts: 4, initial_interval_ms: 1]])

      assert {:error, _} = LangEx.invoke(graph, %{})
      assert count_received(:attempt) == 1
    end

    test "a graph-wide :on_error default is dropped for nodes that cache" do
      graph =
        Graph.new(v: 0)
        |> Graph.add_node(:cached, fn state -> %{v: state.v + 1} end, cache: true)
        |> Graph.add_edge(:__start__, :cached)
        |> Graph.add_edge(:cached, :__end__)
        |> Graph.compile(node_defaults: [on_error: fn _e, _s -> %{v: -1} end])

      assert {:ok, %{v: 1}} = LangEx.invoke(graph, %{v: 0})
    end

    test "an invalid default is rejected at compile time" do
      builder =
        Graph.new()
        |> Graph.add_node(:a, fn _state -> %{} end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :__end__)

      assert_raise ArgumentError, ~r/unknown node option/, fn ->
        Graph.compile(builder, node_defaults: [nonsense: true])
      end
    end
  end

  describe "cache key functions" do
    test "a node keeps its cache when unrelated state changes" do
      test_pid = self()

      graph =
        Graph.new(query: nil, unrelated: nil, result: nil)
        |> Graph.add_node(
          :embed,
          fn state ->
            send(test_pid, {:embedded, state.query})
            %{result: {:vector, state.query}}
          end,
          cache: [key: & &1.query]
        )
        |> Graph.add_edge(:__start__, :embed)
        |> Graph.add_edge(:embed, :__end__)
        |> Graph.compile()

      {:ok, _} = LangEx.invoke(graph, %{query: "cats", unrelated: 1})
      assert_received {:embedded, "cats"}

      {:ok, %{result: {:vector, "cats"}}} =
        LangEx.invoke(graph, %{query: "cats", unrelated: 2})

      refute_received {:embedded, "cats"}

      {:ok, _} = LangEx.invoke(graph, %{query: "dogs", unrelated: 2})
      assert_received {:embedded, "dogs"}
    end

    test "an invalid cache key function is rejected at build time" do
      assert_raise ArgumentError, ~r/1-arity function/, fn ->
        Graph.new()
        |> Graph.add_node(:a, fn _state -> %{} end, cache: [key: :query])
      end
    end

    test "an unknown cache option is rejected at build time" do
      assert_raise ArgumentError, ~r/unknown `cache:` option/, fn ->
        Graph.new()
        |> Graph.add_node(:a, fn _state -> %{} end, cache: [expires: 5])
      end
    end
  end

  defp fail_until(label, attempts) do
    key = {__MODULE__, label, self()}
    seen = :persistent_term.get(key, 0) + 1
    :persistent_term.put(key, seen)
    reached_target(seen >= attempts, key)
  end

  defp reached_target(false, _key), do: raise("not yet")

  defp reached_target(true, key) do
    :persistent_term.erase(key)
    %{attempts: 1}
  end

  defp count_received(message), do: count_received(message, 0)

  defp count_received(message, seen) do
    receive do
      ^message -> count_received(message, seen + 1)
    after
      0 -> seen
    end
  end
end
