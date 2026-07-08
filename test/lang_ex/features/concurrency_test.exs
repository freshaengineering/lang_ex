defmodule LangEx.Features.ConcurrencyTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph
  alias LangEx.Message
  alias LangEx.Tool

  describe "bounded parallel super-steps" do
    test "max_concurrency caps simultaneous node tasks" do
      {:ok, tracker} = Agent.start_link(fn -> %{current: 0, peak: 0} end)

      graph =
        Graph.new(done: {0, &Kernel.+/2})
        |> Graph.add_node(:fanout, fn _state -> %{} end)
        |> add_tracked_workers(tracker, [:w1, :w2, :w3, :w4])
        |> Graph.add_edge(:__start__, :fanout)
        |> Graph.compile()

      {:ok, %{done: 4}} = LangEx.invoke(graph, %{}, max_concurrency: 1)

      assert %{peak: 1} = Agent.get(tracker, & &1)
    end

    @tag :capture_log
    test "node_timeout kills slow parallel nodes" do
      graph =
        Graph.new(a: nil, b: nil)
        |> Graph.add_node(:fast, fn _state -> %{a: :ok} end)
        |> Graph.add_node(:slow, fn _state ->
          Process.sleep(500)
          %{b: :ok}
        end)
        |> Graph.add_edge(:__start__, :fast)
        |> Graph.add_edge(:__start__, :slow)
        |> Graph.add_edge(:fast, :__end__)
        |> Graph.add_edge(:slow, :__end__)
        |> Graph.compile()

      assert {:error,
              %LangEx.NodeError{node: :slow, reason: %LangEx.NodeTimeoutError{timeout_ms: 50}}} =
               LangEx.invoke(graph, %{}, node_timeout: 50)
    end

    @tag :capture_log
    test "node_timeout applies to single-node super-steps" do
      graph =
        Graph.new(value: nil)
        |> Graph.add_node(:slow, fn _state ->
          Process.sleep(500)
          %{value: :ok}
        end)
        |> Graph.add_edge(:__start__, :slow)
        |> Graph.add_edge(:slow, :__end__)
        |> Graph.compile()

      assert {:error,
              %LangEx.NodeError{node: :slow, reason: %LangEx.NodeTimeoutError{timeout_ms: 50}}} =
               LangEx.invoke(graph, %{}, node_timeout: 50)
    end
  end

  describe "bounded tool execution" do
    test "tool timeout raises instead of hanging" do
      tool = %Tool{
        name: "slow_tool",
        description: "sleeps",
        parameters: %{},
        function: fn _args ->
          Process.sleep(500)
          "done"
        end
      }

      node = LangEx.Tool.Node.node([tool], timeout: 50)

      state = %{
        messages: [
          Message.ai(nil,
            tool_calls: [%Message.ToolCall{name: "slow_tool", id: "t1", args: %{}}]
          )
        ]
      }

      assert_raise RuntimeError, "Tool execution timed out", fn -> node.(state) end
    end

    test "tool max_concurrency caps simultaneous tool tasks" do
      {:ok, tracker} = Agent.start_link(fn -> %{current: 0, peak: 0} end)

      tool = %Tool{
        name: "tracked",
        description: "tracks concurrency",
        parameters: %{},
        function: fn _args ->
          track_entry(tracker)
          Process.sleep(30)
          track_exit(tracker)
          "ok"
        end
      }

      node = LangEx.Tool.Node.node([tool], max_concurrency: 1)

      calls =
        Enum.map(1..3, fn i ->
          %Message.ToolCall{name: "tracked", id: "t#{i}", args: %{}}
        end)

      %{messages: results} = node.(%{messages: [Message.ai(nil, tool_calls: calls)]})

      assert length(results) == 3
      assert %{peak: 1} = Agent.get(tracker, & &1)
    end
  end

  defp add_tracked_workers(graph, tracker, names) do
    Enum.reduce(names, graph, fn name, acc ->
      acc
      |> Graph.add_node(name, fn _state ->
        track_entry(tracker)
        Process.sleep(30)
        track_exit(tracker)
        %{done: 1}
      end)
      |> Graph.add_edge(:fanout, name)
      |> Graph.add_edge(name, :__end__)
    end)
  end

  defp track_entry(tracker) do
    Agent.update(tracker, fn %{current: current, peak: peak} ->
      %{current: current + 1, peak: max(peak, current + 1)}
    end)
  end

  defp track_exit(tracker) do
    Agent.update(tracker, fn state -> %{state | current: state.current - 1} end)
  end
end
