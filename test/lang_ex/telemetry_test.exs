defmodule LangEx.TelemetryTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Graph
  alias LangEx.Message

  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  setup do
    handler_id = "telemetry-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      LangEx.Telemetry.events(),
      &__MODULE__.handle_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  describe "graph invoke events" do
    test "emits start and stop for a simple graph" do
      {:ok, _} =
        Graph.new(value: 0)
        |> Graph.add_node(:double, fn state -> %{value: state.value * 2} end)
        |> Graph.add_edge(:__start__, :double)
        |> Graph.add_edge(:double, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{value: 5})

      assert_received {:telemetry, [:lang_ex, :graph, :invoke, :start], %{system_time: _},
                       %{graph_id: :double, thread_id: nil}}

      assert_received {:telemetry, [:lang_ex, :graph, :invoke, :stop], %{duration: duration},
                       %{graph_id: :double, result: :ok}}

      assert is_integer(duration) and duration > 0
    end

    test "tags result as :error on recursion limit" do
      {:error, {:recursion_limit, _, _}} =
        Graph.new(counter: {0, fn _old, new -> new end})
        |> Graph.add_node(:loop, fn state -> %{counter: state.counter + 1} end)
        |> Graph.add_edge(:__start__, :loop)
        |> Graph.add_edge(:loop, :loop)
        |> Graph.compile()
        |> LangEx.invoke(%{}, recursion_limit: 3)

      assert_received {:telemetry, [:lang_ex, :graph, :invoke, :stop], %{duration: _},
                       %{result: :error}}
    end
  end

  describe "step events" do
    test "emits step start/stop for each super-step in a pipeline" do
      {:ok, _} =
        Graph.new(text: "")
        |> Graph.add_node(:upcase, fn state -> %{text: String.upcase(state.text)} end)
        |> Graph.add_node(:exclaim, fn state -> %{text: state.text <> "!"} end)
        |> Graph.add_edge(:__start__, :upcase)
        |> Graph.add_edge(:upcase, :exclaim)
        |> Graph.add_edge(:exclaim, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{text: "hi"})

      assert_received {:telemetry, [:lang_ex, :graph, :step, :start], _,
                       %{step: 0, active_nodes: [:upcase]}}

      assert_received {:telemetry, [:lang_ex, :graph, :step, :stop], %{duration: _}, %{step: 0}}

      assert_received {:telemetry, [:lang_ex, :graph, :step, :start], _,
                       %{step: 1, active_nodes: [:exclaim]}}

      assert_received {:telemetry, [:lang_ex, :graph, :step, :stop], %{duration: _}, %{step: 1}}
    end
  end

  describe "node execute events" do
    test "emits node start/stop for single node execution" do
      {:ok, _} =
        Graph.new(value: 0)
        |> Graph.add_node(:inc, fn state -> %{value: state.value + 1} end)
        |> Graph.add_edge(:__start__, :inc)
        |> Graph.add_edge(:inc, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{value: 0})

      assert_received {:telemetry, [:lang_ex, :node, :execute, :start], %{system_time: _},
                       %{node: :inc}}

      assert_received {:telemetry, [:lang_ex, :node, :execute, :stop], %{duration: _},
                       %{node: :inc}}
    end

    test "emits node events for parallel nodes" do
      {:ok, _} =
        Graph.new(a_val: nil, b_val: nil)
        |> Graph.add_node(:a, fn _state -> %{a_val: "from_a"} end)
        |> Graph.add_node(:b, fn _state -> %{b_val: "from_b"} end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:__start__, :b)
        |> Graph.add_edge(:a, :__end__)
        |> Graph.add_edge(:b, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{})

      assert_received {:telemetry, [:lang_ex, :node, :execute, :start], _, %{node: :a}}
      assert_received {:telemetry, [:lang_ex, :node, :execute, :stop], _, %{node: :a}}
      assert_received {:telemetry, [:lang_ex, :node, :execute, :start], _, %{node: :b}}
      assert_received {:telemetry, [:lang_ex, :node, :execute, :stop], _, %{node: :b}}
    end
  end

  describe "LLM chat events" do
    test "emits chat start/stop with provider metadata" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("Hello!"), %{input_tokens: 10, output_tokens: 5}}
      end)

      {:ok, _} =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(
          :llm,
          LangEx.LLM.ChatModel.node(provider: LangEx.LLM.OpenAI, model: "gpt-4o")
        )
        |> Graph.add_edge(:__start__, :llm)
        |> Graph.add_edge(:llm, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{messages: [Message.human("Hi")]})

      assert_received {:telemetry, [:lang_ex, :llm, :chat, :start], %{system_time: _},
                       %{provider: LangEx.LLM.OpenAI, model: "gpt-4o", message_count: 1}}

      assert_received {:telemetry, [:lang_ex, :llm, :chat, :stop], %{duration: _},
                       %{
                         provider: LangEx.LLM.OpenAI,
                         model: "gpt-4o",
                         status: :ok,
                         usage: %{input_tokens: 10, output_tokens: 5}
                       }}
    end
  end

  describe "run-tree correlation" do
    test "spans carry run_id/parent_run_id forming a tree" do
      {:ok, _} =
        Graph.new(value: 0)
        |> Graph.add_node(:inc, fn state -> %{value: state.value + 1} end)
        |> Graph.add_edge(:__start__, :inc)
        |> Graph.add_edge(:inc, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{value: 0})

      assert_received {:telemetry, [:lang_ex, :graph, :invoke, :start], _,
                       %{run_id: invoke_id, parent_run_id: nil}}

      assert_received {:telemetry, [:lang_ex, :graph, :step, :start], _,
                       %{run_id: step_id, parent_run_id: ^invoke_id}}

      assert_received {:telemetry, [:lang_ex, :node, :execute, :start], _,
                       %{run_id: node_id, parent_run_id: ^step_id}}

      assert is_binary(invoke_id) and is_binary(step_id) and is_binary(node_id)
    end

    test "parallel node spans inherit the step run_id across processes" do
      {:ok, _} =
        Graph.new(a_val: nil, b_val: nil)
        |> Graph.add_node(:a, fn _state -> %{a_val: "a"} end)
        |> Graph.add_node(:b, fn _state -> %{b_val: "b"} end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:__start__, :b)
        |> Graph.add_edge(:a, :__end__)
        |> Graph.add_edge(:b, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{})

      assert_received {:telemetry, [:lang_ex, :graph, :step, :start], _, %{run_id: step_id}}

      assert_received {:telemetry, [:lang_ex, :node, :execute, :start], _,
                       %{node: :a, parent_run_id: ^step_id}}

      assert_received {:telemetry, [:lang_ex, :node, :execute, :start], _,
                       %{node: :b, parent_run_id: ^step_id}}
    end

    test "compile-time name becomes the graph_id" do
      {:ok, _} =
        Graph.new(value: 0)
        |> Graph.add_node(:inc, fn state -> %{value: state.value + 1} end)
        |> Graph.add_edge(:__start__, :inc)
        |> Graph.add_edge(:inc, :__end__)
        |> Graph.compile(name: :counter_flow)
        |> LangEx.invoke(%{value: 0})

      assert_received {:telemetry, [:lang_ex, :graph, :invoke, :start], _,
                       %{graph_id: :counter_flow}}
    end
  end

  describe "OpenTelemetry bridge" do
    test "attaches and handles a full run without a configured SDK" do
      assert :ok = LangEx.Telemetry.OpenTelemetryBridge.attach()
      on_exit(fn -> LangEx.Telemetry.OpenTelemetryBridge.detach() end)

      assert {:ok, %{value: 2}} =
               Graph.new(value: 0)
               |> Graph.add_node(:double, fn state -> %{value: state.value * 2} end)
               |> Graph.add_edge(:__start__, :double)
               |> Graph.add_edge(:double, :__end__)
               |> Graph.compile()
               |> LangEx.invoke(%{value: 1})
    end
  end

  describe "events/0" do
    test "returns all 18 event names" do
      events = LangEx.Telemetry.events()

      assert length(events) == 18
      assert [:lang_ex, :graph, :invoke, :start] in events
      assert [:lang_ex, :graph, :invoke, :stop] in events
      assert [:lang_ex, :graph, :invoke, :exception] in events
      assert [:lang_ex, :node, :execute, :start] in events
      assert [:lang_ex, :llm, :chat, :stop] in events
      assert [:lang_ex, :checkpoint, :save, :start] in events
      assert [:lang_ex, :checkpoint, :load, :stop] in events
    end
  end
end
