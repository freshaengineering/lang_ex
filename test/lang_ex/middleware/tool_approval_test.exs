defmodule LangEx.Middleware.ToolApprovalTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Command
  alias LangEx.Message
  alias LangEx.Middleware.ToolApproval
  alias LangEx.Prebuilt
  alias LangEx.Tool

  setup do
    LangEx.Checkpointer.Memory.clear()
    :ok
  end

  describe "reviewing a guarded call" do
    test "the run pauses with what the model wants to do" do
      graph = agent(ToolApproval.new(tools: ["restart"]), [restart_tool()])
      answer_with([call("restart", %{"service" => "api"})])

      assert {:interrupt, payload, _state} =
               LangEx.invoke(graph, opening("api is wedged"), config: thread())

      assert %{type: :tool_approval, tool: "restart", args: %{"service" => "api"}} = payload
    end

    test "an approved call runs" do
      graph = agent(ToolApproval.new(tools: ["restart"]), [restart_tool()])
      answer_with([call("restart", %{"service" => "api"})], "restarted")

      {:interrupt, _payload, _paused} =
        LangEx.invoke(graph, opening("api is wedged"), config: thread("a"))

      assert {:ok, result} =
               LangEx.invoke(graph, %Command{resume: :approve}, config: thread("a"))

      assert_received {:ran, %{"service" => "api"}}
      assert %Message.AI{content: "restarted"} = List.last(result.messages)
    end

    test "a refused call is answered as an error the model can react to" do
      graph = agent(ToolApproval.new(tools: ["restart"]), [restart_tool()])
      answer_with([call("restart", %{"service" => "api"})], "understood")

      {:interrupt, _payload, _paused} =
        LangEx.invoke(graph, opening("api is wedged"), config: thread("b"))

      assert {:ok, result} =
               LangEx.invoke(graph, %Command{resume: {:reject, "peak traffic"}},
                 config: thread("b")
               )

      refute_received {:ran, _args}

      assert %Message.Tool{status: :error, content: content} = tool_reply(result)
      assert content =~ "peak traffic"
    end

    test "a reviewer's corrected arguments are what the tool receives" do
      graph = agent(ToolApproval.new(tools: ["restart"]), [restart_tool()])
      answer_with([call("restart", %{"service" => "api"})], "restarted")

      {:interrupt, _payload, _paused} =
        LangEx.invoke(graph, opening("api is wedged"), config: thread("c"))

      {:ok, _result} =
        LangEx.invoke(graph, %Command{resume: {:approve, %{"service" => "api-canary"}}},
          config: thread("c")
        )

      assert_received {:ran, %{"service" => "api-canary"}}
    end

    test "a reviewer can answer the call instead of running the tool" do
      graph = agent(ToolApproval.new(tools: ["restart"]), [restart_tool()])
      answer_with([call("restart", %{"service" => "api"})], "thanks")

      {:interrupt, _payload, _paused} =
        LangEx.invoke(graph, opening("api is wedged"), config: thread("d"))

      {:ok, result} =
        LangEx.invoke(graph, %Command{resume: {:respond, "already restarted by hand"}},
          config: thread("d")
        )

      refute_received {:ran, _args}
      assert %Message.Tool{content: "already restarted by hand", status: :ok} = tool_reply(result)
    end

    test "an unusable decision names the ones that work" do
      graph = agent(ToolApproval.new(tools: ["restart"]), [restart_tool()])
      answer_with([call("restart", %{"service" => "api"})])

      {:interrupt, _payload, _paused} =
        LangEx.invoke(graph, opening("api is wedged"), config: thread("e"))

      assert {:error, %LangEx.NodeError{node: :before_tools, reason: reason}} =
               LangEx.invoke(graph, %Command{resume: :yes_please}, config: thread("e"))

      assert %ArgumentError{message: message} = reason
      assert message =~ "resume with :approve"
    end
  end

  describe "scope" do
    test "an unguarded call runs without review" do
      graph = agent(ToolApproval.new(tools: ["restart"]), [restart_tool(), read_tool()])
      answer_with([call("read", %{"path" => "log"})], "read it")

      assert {:ok, result} = LangEx.invoke(graph, opening("check the log"), config: thread("f"))

      assert_received {:read, %{"path" => "log"}}
      assert %Message.AI{content: "read it"} = List.last(result.messages)
    end

    test "refusing one call still runs the others in the batch" do
      graph = agent(ToolApproval.new(tools: ["restart"]), [restart_tool(), read_tool()])

      answer_with(
        [call("restart", %{"service" => "api"}), call("read", %{"path" => "log"})],
        "understood"
      )

      {:interrupt, _payload, _paused} =
        LangEx.invoke(graph, opening("look then restart"), config: thread("g"))

      {:ok, result} = LangEx.invoke(graph, %Command{resume: :reject}, config: thread("g"))

      refute_received {:ran, _args}
      assert_received {:read, %{"path" => "log"}}

      assert [%Message.Tool{status: :error}, %Message.Tool{content: "log contents"}] =
               Enum.filter(result.messages, &match?(%Message.Tool{}, &1))
    end

    test "each guarded call in a batch is reviewed on its own" do
      graph = agent(ToolApproval.new(tools: :all), [restart_tool(), read_tool()])

      answer_with(
        [call("restart", %{"service" => "api"}), call("read", %{"path" => "log"})],
        "done"
      )

      assert {:interrupt, %{tool: "restart"}, _} =
               LangEx.invoke(graph, opening("look then restart"), config: thread("h"))

      assert {:interrupt, %{tool: "read"}, _} =
               LangEx.invoke(graph, %Command{resume: :reject}, config: thread("h"))

      {:ok, result} = LangEx.invoke(graph, %Command{resume: :approve}, config: thread("h"))

      refute_received {:ran, _args}
      assert_received {:read, %{"path" => "log"}}

      assert [%Message.Tool{status: :error}, %Message.Tool{content: "log contents"}] =
               Enum.filter(result.messages, &match?(%Message.Tool{}, &1))
    end
  end

  describe "resume cost" do
    test "resuming does not repeat the model call under review" do
      graph = agent(ToolApproval.new(tools: ["restart"]), [restart_tool()])
      answer_with([call("restart", %{"service" => "api"})], "restarted")

      {:interrupt, _payload, _paused} =
        LangEx.invoke(graph, opening("api is wedged"), config: thread("i"))

      assert_received {:model_called, _}

      {:ok, _result} = LangEx.invoke(graph, %Command{resume: :approve}, config: thread("i"))

      assert_received {:model_called, _}
      refute_received {:model_called, _}
    end
  end

  defp agent(middleware, tools) do
    Prebuilt.agent(
      provider: LangEx.LLM.OpenAI,
      model: "gpt-4o",
      tools: tools,
      middleware: [middleware],
      checkpointer: LangEx.Checkpointer.Memory
    )
  end

  # First model call requests the tools; every later call answers in prose so
  # the agent loop terminates.
  defp answer_with(tool_calls, final \\ "done") do
    test_pid = self()
    counter = :counters.new(1, [])

    stub(LangEx.LLM.OpenAI, :chat_with_usage, fn messages, _opts ->
      send(test_pid, {:model_called, length(messages)})
      :counters.add(counter, 1, 1)

      counter
      |> :counters.get(1)
      |> reply(tool_calls, final)
    end)
  end

  defp reply(1, tool_calls, _final),
    do: {:ok, Message.ai(nil, id: "ai-1", tool_calls: tool_calls), usage()}

  defp reply(_n, _tool_calls, final), do: {:ok, Message.ai(final), usage()}

  defp usage, do: %{input_tokens: 1, output_tokens: 1}

  defp call(name, args), do: %Message.ToolCall{name: name, id: "call-#{name}", args: args}

  defp opening(text), do: %{messages: [Message.human(text)]}

  defp thread(id \\ "t"), do: [thread_id: "approval-#{id}"]

  defp tool_reply(result), do: Enum.find(result.messages, &match?(%Message.Tool{}, &1))

  defp restart_tool do
    test_pid = self()

    %Tool{
      name: "restart",
      description: "restart a service",
      parameters: %{},
      function: fn args ->
        send(test_pid, {:ran, args})
        "restarted #{args["service"]}"
      end
    }
  end

  defp read_tool do
    test_pid = self()

    %Tool{
      name: "read",
      description: "read a file",
      parameters: %{},
      function: fn args ->
        send(test_pid, {:read, args})
        "log contents"
      end
    }
  end
end
