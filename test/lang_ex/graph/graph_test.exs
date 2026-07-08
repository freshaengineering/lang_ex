defmodule LangEx.Graph.ValidationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias LangEx.Graph

  describe "compile-time validation" do
    test "conditional edge mapping targets must be defined nodes" do
      assert_raise ArgumentError, ~r/conditional edge target from :router/, fn ->
        Graph.new(intent: nil)
        |> Graph.add_node(:router, fn state -> state end)
        |> Graph.add_edge(:__start__, :router)
        |> Graph.add_conditional_edges(:router, & &1.intent, %{"qa" => :missing_node})
        |> Graph.compile()
      end
    end

    test "unreachable nodes produce a compile warning" do
      warning =
        capture_io(:stderr, fn ->
          Graph.new(value: 0)
          |> Graph.add_node(:used, fn state -> state end)
          |> Graph.add_node(:orphan, fn state -> state end)
          |> Graph.add_edge(:__start__, :used)
          |> Graph.add_edge(:used, :__end__)
          |> Graph.compile()
        end)

      assert warning =~ "not reachable via declared edges: [:orphan]"
    end

    test "no warning when a mapping-less conditional edge exists" do
      warning =
        capture_io(:stderr, fn ->
          Graph.new(value: 0)
          |> Graph.add_node(:router, fn _state -> :dynamic_target end)
          |> Graph.add_node(:dynamic_target, fn state -> state end)
          |> Graph.add_edge(:__start__, :router)
          |> Graph.add_conditional_edges(:router, fn _state -> :dynamic_target end)
          |> Graph.add_edge(:dynamic_target, :__end__)
          |> Graph.compile()
        end)

      assert warning == ""
    end

    test "interrupt breakpoints must reference defined nodes" do
      builder =
        Graph.new(value: 0)
        |> Graph.add_node(:work, fn state -> state end)
        |> Graph.add_edge(:__start__, :work)
        |> Graph.add_edge(:work, :__end__)

      assert_raise ArgumentError, ~r/:interrupt_before references undefined node/, fn ->
        Graph.compile(builder, interrupt_before: [:missing])
      end

      assert_raise ArgumentError, ~r/:interrupt_after references undefined node/, fn ->
        Graph.compile(builder, interrupt_after: [:missing])
      end
    end
  end

  describe "build-time validation" do
    test "duplicate node names raise" do
      assert_raise ArgumentError, ~r/node :dup is already defined/, fn ->
        Graph.new(value: 0)
        |> Graph.add_node(:dup, fn state -> state end)
        |> Graph.add_node(:dup, fn state -> state end)
      end
    end

    test "reserved node names raise" do
      assert_raise ArgumentError, ~r/:__start__ is a reserved node name/, fn ->
        Graph.new(value: 0) |> Graph.add_node(:__start__, fn state -> state end)
      end

      assert_raise ArgumentError, ~r/:__end__ is a reserved node name/, fn ->
        Graph.new(value: 0) |> Graph.add_node(:__end__, fn state -> state end)
      end
    end

    test "edges cannot start from :__end__" do
      assert_raise ArgumentError, ~r/:__end__ is terminal/, fn ->
        Graph.new(value: 0)
        |> Graph.add_node(:work, fn state -> state end)
        |> Graph.add_edge(:__end__, :work)
      end
    end

    test "a node has at most one routing function" do
      assert_raise ArgumentError, ~r/conditional edges from :router are already defined/, fn ->
        Graph.new(value: 0)
        |> Graph.add_node(:router, fn state -> state end)
        |> Graph.add_conditional_edges(:router, fn _state -> :__end__ end)
        |> Graph.add_conditional_edges(:router, fn _state -> :__end__ end)
      end
    end

    test "invalid node option values raise" do
      assert_raise ArgumentError, ~r/invalid value 0 for node option :timeout/, fn ->
        Graph.new(value: 0) |> Graph.add_node(:bad, fn state -> state end, timeout: 0)
      end

      assert_raise ArgumentError, ~r/invalid value "yes" for node option :defer/, fn ->
        Graph.new(value: 0) |> Graph.add_node(:bad, fn state -> state end, defer: "yes")
      end
    end

    test "cache and on_error cannot be combined" do
      assert_raise ArgumentError, ~r/combines :cache with :on_error/, fn ->
        Graph.new(value: 0)
        |> Graph.add_node(:bad, fn state -> state end,
          cache: true,
          on_error: fn _error, _state -> %{} end
        )
      end
    end
  end

  describe "runtime target validation" do
    test "Command goto to an undefined node raises with a clear message" do
      graph =
        Graph.new(value: 0)
        |> Graph.add_node(:router, fn _state ->
          %LangEx.Command{update: %{}, goto: :missing}
        end)
        |> Graph.add_edge(:__start__, :router)
        |> Graph.compile(warn_unreachable: false)

      assert_raise ArgumentError, ~r/cannot execute undefined node\(s\) \[:missing\]/, fn ->
        LangEx.invoke(graph, %{})
      end
    end
  end

  describe "to_mermaid/1" do
    test "renders nodes, static edges, and labelled conditional edges" do
      mermaid =
        Graph.new(intent: nil)
        |> Graph.add_node(:router, fn state -> state end)
        |> Graph.add_node(:qa, fn state -> state end)
        |> Graph.add_edge(:__start__, :router)
        |> Graph.add_conditional_edges(:router, & &1.intent, %{"qa" => :qa, "done" => :__end__})
        |> Graph.add_edge(:qa, :__end__)
        |> Graph.compile()
        |> Graph.to_mermaid()

      assert mermaid =~ "flowchart TD"
      assert mermaid =~ "__start__ --> router"
      assert mermaid =~ "qa --> __end__"
      assert mermaid =~ "router -.->|qa| qa"
      assert mermaid =~ "router -.->|done| __end__"
    end
  end
end

defmodule LangEx.GraphTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph
  alias LangEx.Command

  describe "linear graph execution" do
    test "single-node graph processes state and returns result" do
      {:ok, result} =
        Graph.new(value: 0)
        |> Graph.add_node(:double, fn state -> %{value: state.value * 2} end)
        |> Graph.add_edge(:__start__, :double)
        |> Graph.add_edge(:double, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{value: 5})

      assert %{value: 10} = result
    end

    test "multi-node linear pipeline chains transformations" do
      {:ok, result} =
        Graph.new(text: "")
        |> Graph.add_node(:upcase, fn state -> %{text: String.upcase(state.text)} end)
        |> Graph.add_node(:exclaim, fn state -> %{text: state.text <> "!"} end)
        |> Graph.add_edge(:__start__, :upcase)
        |> Graph.add_edge(:upcase, :exclaim)
        |> Graph.add_edge(:exclaim, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{text: "hello"})

      assert %{text: "HELLO!"} = result
    end
  end

  describe "conditional routing" do
    test "routes to different nodes based on state" do
      router = fn
        %{value: v} when v > 10 -> :big
        _ -> :small
      end

      {:ok, result} =
        Graph.new(value: 0, label: "")
        |> Graph.add_node(:big, fn _state -> %{label: "big"} end)
        |> Graph.add_node(:small, fn _state -> %{label: "small"} end)
        |> Graph.add_node(:check, fn state -> %{value: state.value} end)
        |> Graph.add_edge(:__start__, :check)
        |> Graph.add_conditional_edges(:check, router)
        |> Graph.add_edge(:big, :__end__)
        |> Graph.add_edge(:small, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{value: 42})

      assert %{value: 42, label: "big"} = result
    end

    test "routes with explicit mapping" do
      {:ok, result} =
        Graph.new(status: "")
        |> Graph.add_node(:pass, fn _state -> %{status: "passed"} end)
        |> Graph.add_node(:fail, fn _state -> %{status: "failed"} end)
        |> Graph.add_conditional_edges(
          :__start__,
          fn %{status: s} -> s end,
          %{"ok" => :pass, "error" => :fail}
        )
        |> Graph.add_edge(:pass, :__end__)
        |> Graph.add_edge(:fail, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{status: "error"})

      assert %{status: "failed"} = result
    end
  end

  describe "state reducers" do
    test "append reducer accumulates list values across nodes" do
      {:ok, result} =
        Graph.new(log: {[], &Kernel.++/2})
        |> Graph.add_node(:a, fn _state -> %{log: ["step_a"]} end)
        |> Graph.add_node(:b, fn _state -> %{log: ["step_b"]} end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :b)
        |> Graph.add_edge(:b, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{})

      assert %{log: ["step_a", "step_b"]} = result
    end

    test "sum reducer accumulates numeric values" do
      {:ok, result} =
        Graph.new(total: {0, &Kernel.+/2})
        |> Graph.add_node(:add_five, fn _state -> %{total: 5} end)
        |> Graph.add_node(:add_three, fn _state -> %{total: 3} end)
        |> Graph.add_edge(:__start__, :add_five)
        |> Graph.add_edge(:add_five, :add_three)
        |> Graph.add_edge(:add_three, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{})

      assert %{total: 8} = result
    end
  end

  describe "cycles and recursion limit" do
    test "loop terminates via conditional edge to :__end__" do
      {:ok, result} =
        Graph.new(counter: {0, fn _old, new -> new end})
        |> Graph.add_node(:increment, fn state -> %{counter: state.counter + 1} end)
        |> Graph.add_edge(:__start__, :increment)
        |> Graph.add_conditional_edges(:increment, fn
          %{counter: c} when c >= 3 -> :__end__
          _ -> :increment
        end)
        |> Graph.compile()
        |> LangEx.invoke(%{})

      assert %{counter: 3} = result
    end

    test "exceeding recursion limit returns error" do
      {:error, {:recursion_limit, _, _}} =
        Graph.new(counter: {0, fn _old, new -> new end})
        |> Graph.add_node(:loop, fn state -> %{counter: state.counter + 1} end)
        |> Graph.add_edge(:__start__, :loop)
        |> Graph.add_edge(:loop, :loop)
        |> Graph.compile()
        |> LangEx.invoke(%{}, recursion_limit: 5)
    end
  end

  describe "Command-based routing" do
    test "node returning Command updates state and redirects" do
      {:ok, result} =
        Graph.new(value: 0, routed: false)
        |> Graph.add_node(:decide, fn state ->
          %Command{update: %{value: state.value + 100}, goto: :finish}
        end)
        |> Graph.add_node(:finish, fn _state -> %{routed: true} end)
        |> Graph.add_edge(:__start__, :decide)
        |> Graph.add_edge(:finish, :__end__)
        |> Graph.compile(warn_unreachable: false)
        |> LangEx.invoke(%{value: 1})

      assert %{value: 101, routed: true} = result
    end
  end

  describe "validation" do
    test "compile raises without a :__start__ edge" do
      assert_raise ArgumentError, ~r/must have an edge from :__start__/, fn ->
        Graph.new(x: 0)
        |> Graph.add_node(:a, fn s -> s end)
        |> Graph.add_edge(:a, :__end__)
        |> Graph.compile()
      end
    end

    test "compile raises for edges referencing undefined nodes" do
      assert_raise ArgumentError, ~r/not a defined node/, fn ->
        Graph.new(x: 0)
        |> Graph.add_node(:a, fn s -> s end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :nonexistent)
        |> Graph.compile()
      end
    end
  end
end
