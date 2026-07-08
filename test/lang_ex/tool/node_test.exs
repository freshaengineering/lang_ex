defmodule LangEx.Tool.NodeTest do
  use ExUnit.Case, async: true

  alias LangEx.Message
  alias LangEx.Tool
  alias LangEx.Tool.Node, as: ToolNode
  alias LangEx.Tool.Node.ToolCallRequest

  defp echo_tool do
    %Tool{
      name: "echo",
      description: "Echo args back",
      parameters: %{type: "object", properties: %{text: %{type: "string"}}, required: ["text"]},
      function: fn %{"text" => text} -> %{echoed: text} end
    }
  end

  defp add_tool do
    %Tool{
      name: "add",
      description: "Add two numbers",
      parameters: %{type: "object", properties: %{a: %{type: "integer"}, b: %{type: "integer"}}},
      function: fn %{"a" => a, "b" => b} -> %{result: a + b} end
    }
  end

  defp stateful_tool do
    %Tool{
      name: "count_messages",
      description: "Count messages in state",
      parameters: %{type: "object", properties: %{}},
      function: fn _args, %{state: state} ->
        %{count: length(state.messages)}
      end
    }
  end

  defp failing_tool do
    %Tool{
      name: "fail",
      description: "Always fails",
      parameters: %{},
      function: fn _args -> raise "boom" end
    }
  end

  defp state_with_tool_calls(tool_calls) do
    ai = Message.ai(nil, tool_calls: tool_calls)
    %{messages: [Message.human("hi"), ai]}
  end

  describe "node/2 basic execution" do
    test "executes a single tool call and returns Tool message" do
      node_fn = ToolNode.node([echo_tool()])
      call = %Message.ToolCall{name: "echo", id: "c1", args: %{"text" => "hello"}}
      state = state_with_tool_calls([call])

      result = node_fn.(state)

      assert %{messages: [%Message.Tool{tool_call_id: "c1", content: content}]} = result
      assert Jason.decode!(content) == %{"echoed" => "hello"}
    end

    test "executes multiple tool calls in parallel" do
      node_fn = ToolNode.node([echo_tool(), add_tool()])

      calls = [
        %Message.ToolCall{name: "echo", id: "c1", args: %{"text" => "hi"}},
        %Message.ToolCall{name: "add", id: "c2", args: %{"a" => 3, "b" => 4}}
      ]

      state = state_with_tool_calls(calls)
      result = node_fn.(state)

      assert %{messages: [tool1, tool2]} = result
      assert %Message.Tool{tool_call_id: "c1"} = tool1
      assert %Message.Tool{tool_call_id: "c2"} = tool2
      assert Jason.decode!(tool2.content) == %{"result" => 7}
    end

    test "preserves tool call order" do
      node_fn = ToolNode.node([echo_tool(), add_tool()])

      calls = [
        %Message.ToolCall{name: "add", id: "first", args: %{"a" => 1, "b" => 2}},
        %Message.ToolCall{name: "echo", id: "second", args: %{"text" => "ok"}}
      ]

      state = state_with_tool_calls(calls)
      %{messages: [t1, t2]} = node_fn.(state)
      assert t1.tool_call_id == "first"
      assert t2.tool_call_id == "second"
    end
  end

  describe "arity-2 functions (state access)" do
    test "passes state to arity-2 tool functions" do
      node_fn = ToolNode.node([stateful_tool()])
      call = %Message.ToolCall{name: "count_messages", id: "c1", args: %{}}
      state = state_with_tool_calls([call])

      %{messages: [%Message.Tool{content: content}]} = node_fn.(state)
      assert Jason.decode!(content) == %{"count" => 2}
    end

    test "passes tool_call_id in context" do
      tool = %Tool{
        name: "id_check",
        description: "Returns its own call id",
        parameters: %{},
        function: fn _args, %{tool_call_id: id} -> %{call_id: id} end
      }

      node_fn = ToolNode.node([tool])
      call = %Message.ToolCall{name: "id_check", id: "xyz", args: %{}}
      state = state_with_tool_calls([call])

      %{messages: [%Message.Tool{content: content}]} = node_fn.(state)
      assert Jason.decode!(content) == %{"call_id" => "xyz"}
    end
  end

  describe "invalid tool name" do
    test "returns error message for unregistered tool (handle_tool_errors: true)" do
      node_fn = ToolNode.node([echo_tool()], handle_tool_errors: true)
      call = %Message.ToolCall{name: "nonexistent", id: "c1", args: %{}}
      state = state_with_tool_calls([call])

      %{messages: [%Message.Tool{content: content, tool_call_id: "c1"}]} = node_fn.(state)
      assert content =~ "not a valid tool"
      assert content =~ "echo"
    end

    @tag capture_log: true
    test "raises for unregistered tool when handle_tool_errors: false" do
      node_fn = ToolNode.node([echo_tool()], handle_tool_errors: false)
      call = %Message.ToolCall{name: "nonexistent", id: "c1", args: %{}}
      state = state_with_tool_calls([call])

      assert_raise ArgumentError, ~r/not a valid tool/, fn -> node_fn.(state) end
    end
  end

  describe "error handling" do
    @tag capture_log: true
    test "handle_tool_errors: true returns error ToolMessage" do
      node_fn = ToolNode.node([failing_tool()], handle_tool_errors: true)
      call = %Message.ToolCall{name: "fail", id: "c1", args: %{}}
      state = state_with_tool_calls([call])

      %{messages: [%Message.Tool{content: content, tool_call_id: "c1"}]} = node_fn.(state)
      assert content =~ "boom"
    end

    @tag capture_log: true
    test "handle_tool_errors: false propagates exception" do
      node_fn = ToolNode.node([failing_tool()], handle_tool_errors: false)
      call = %Message.ToolCall{name: "fail", id: "c1", args: %{}}
      state = state_with_tool_calls([call])

      assert_raise RuntimeError, "boom", fn -> node_fn.(state) end
    end

    @tag capture_log: true
    test "handle_tool_errors: string returns custom message" do
      node_fn = ToolNode.node([failing_tool()], handle_tool_errors: "Something went wrong")
      call = %Message.ToolCall{name: "fail", id: "c1", args: %{}}
      state = state_with_tool_calls([call])

      %{messages: [%Message.Tool{content: "Something went wrong"}]} = node_fn.(state)
    end

    @tag capture_log: true
    test "handle_tool_errors: function gets the exception" do
      handler = fn e -> "Custom: #{Exception.message(e)}" end
      node_fn = ToolNode.node([failing_tool()], handle_tool_errors: handler)
      call = %Message.ToolCall{name: "fail", id: "c1", args: %{}}
      state = state_with_tool_calls([call])

      %{messages: [%Message.Tool{content: "Custom: boom"}]} = node_fn.(state)
    end
  end

  describe "interrupts inside tool functions" do
    test "interrupt/1 in a tool surfaces as an error tool message, not a crash" do
      tool = %Tool{
        name: "pause",
        description: "Tries to interrupt",
        parameters: %{},
        function: fn _args -> LangEx.Interrupt.interrupt("cannot pause here") end
      }

      node_fn = ToolNode.node([tool])
      call = %Message.ToolCall{name: "pause", id: "c1", args: %{}}

      assert %{messages: [%Message.Tool{tool_call_id: "c1", content: content}]} =
               node_fn.(state_with_tool_calls([call]))

      assert content =~ "outside a graph node"
    end
  end

  describe "tools_condition/2" do
    test "returns :tools when last message has tool_calls" do
      call = %Message.ToolCall{name: "echo", id: "c1", args: %{}}
      state = %{messages: [Message.ai(nil, tool_calls: [call])]}

      assert ToolNode.tools_condition(state) == :tools
    end

    test "returns :__end__ when last message has no tool_calls" do
      state = %{messages: [Message.ai("Hello!")]}
      assert ToolNode.tools_condition(state) == :__end__
    end

    test "returns :__end__ when last message is human" do
      state = %{messages: [Message.human("hi")]}
      assert ToolNode.tools_condition(state) == :__end__
    end

    test "returns :__end__ for empty messages" do
      assert ToolNode.tools_condition(%{messages: []}) == :__end__
    end

    test "respects custom messages_key" do
      call = %Message.ToolCall{name: "echo", id: "c1", args: %{}}
      state = %{chat: [Message.ai(nil, tool_calls: [call])]}

      assert ToolNode.tools_condition(state, messages_key: :chat) == :tools
    end
  end

  describe "custom messages_key" do
    test "reads from and writes to custom key" do
      node_fn = ToolNode.node([echo_tool()], messages_key: :chat)
      call = %Message.ToolCall{name: "echo", id: "c1", args: %{"text" => "custom"}}
      ai = Message.ai(nil, tool_calls: [call])
      state = %{chat: [ai]}

      result = node_fn.(state)
      assert %{chat: [%Message.Tool{tool_call_id: "c1"}]} = result
    end
  end

  describe "wrap_tool_call interceptor" do
    test "passthrough interceptor works" do
      interceptor = fn request, execute -> execute.(request) end
      node_fn = ToolNode.node([echo_tool()], wrap_tool_call: interceptor)
      call = %Message.ToolCall{name: "echo", id: "c1", args: %{"text" => "pass"}}
      state = state_with_tool_calls([call])

      %{messages: [%Message.Tool{content: content}]} = node_fn.(state)
      assert Jason.decode!(content) == %{"echoed" => "pass"}
    end

    test "interceptor can modify args" do
      interceptor = fn %ToolCallRequest{tool_call: call} = request, execute ->
        modified_call = %{call | args: Map.put(call.args, "text", "intercepted")}
        execute.(%{request | tool_call: modified_call})
      end

      node_fn = ToolNode.node([echo_tool()], wrap_tool_call: interceptor)
      call = %Message.ToolCall{name: "echo", id: "c1", args: %{"text" => "original"}}
      state = state_with_tool_calls([call])

      %{messages: [%Message.Tool{content: content}]} = node_fn.(state)
      assert Jason.decode!(content) == %{"echoed" => "intercepted"}
    end

    test "interceptor can short-circuit without calling execute" do
      interceptor = fn %ToolCallRequest{tool_call: call}, _execute ->
        Message.tool(~s({"cached":true}), call.id)
      end

      node_fn = ToolNode.node([echo_tool()], wrap_tool_call: interceptor)
      call = %Message.ToolCall{name: "echo", id: "c1", args: %{"text" => "skip"}}
      state = state_with_tool_calls([call])

      %{messages: [%Message.Tool{content: content}]} = node_fn.(state)
      assert Jason.decode!(content) == %{"cached" => true}
    end

    test "interceptor receives ToolCallRequest with correct fields" do
      test_pid = self()

      interceptor = fn request, execute ->
        send(test_pid, {:request, request})
        execute.(request)
      end

      node_fn = ToolNode.node([echo_tool()], wrap_tool_call: interceptor)
      call = %Message.ToolCall{name: "echo", id: "c1", args: %{"text" => "check"}}
      state = state_with_tool_calls([call])

      node_fn.(state)

      assert_received {:request,
                       %ToolCallRequest{
                         tool_call: %Message.ToolCall{name: "echo", id: "c1"},
                         tool: %Tool{name: "echo"},
                         state: ^state
                       }}
    end
  end

  describe "string result passthrough" do
    test "string results are not double-encoded" do
      tool = %Tool{
        name: "raw",
        description: "Returns raw string",
        parameters: %{},
        function: fn _args -> "plain text" end
      }

      node_fn = ToolNode.node([tool])
      call = %Message.ToolCall{name: "raw", id: "c1", args: %{}}
      state = state_with_tool_calls([call])

      %{messages: [%Message.Tool{content: "plain text"}]} = node_fn.(state)
    end
  end
end
