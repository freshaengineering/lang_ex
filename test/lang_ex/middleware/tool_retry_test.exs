defmodule LangEx.Middleware.ToolRetryTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Message
  alias LangEx.Middleware.ToolRetry
  alias LangEx.Prebuilt
  alias LangEx.Tool

  describe "transient failure" do
    test "a tool that fails once and then works never reaches the model" do
      answers_then_stops()
      graph = agent(ToolRetry.new(max_attempts: 3), [flaky_tool(1)])

      {:ok, result} = LangEx.invoke(graph, opening())

      assert %Message.Tool{status: :ok, content: "metrics"} = tool_reply(result)
      assert 2 == attempts()
    end

    test "the model is told about a failure that outlasts the retries" do
      answers_then_stops()
      graph = agent(ToolRetry.new(max_attempts: 2), [flaky_tool(99)])

      {:ok, result} = LangEx.invoke(graph, opening())

      assert %Message.Tool{status: :error, content: content} = tool_reply(result)
      assert content =~ "still down"
      assert 2 == attempts()
    end

    test "a tool that works first time is called once" do
      answers_then_stops()
      graph = agent(ToolRetry.new(max_attempts: 3), [flaky_tool(0)])

      {:ok, _result} = LangEx.invoke(graph, opening())

      assert 1 == attempts()
    end
  end

  describe "scope" do
    test "a tool outside the retry list is left alone" do
      answers_then_stops()
      graph = agent(ToolRetry.new(max_attempts: 3, tools: ["other"]), [flaky_tool(1)])

      {:ok, result} = LangEx.invoke(graph, opening())

      assert %Message.Tool{status: :error} = tool_reply(result)
      assert 1 == attempts()
    end
  end

  describe "backoff" do
    test "a growing delay is waited out between attempts" do
      answers_then_stops()

      graph =
        agent(ToolRetry.new(max_attempts: 3, backoff: fn attempt -> attempt * 20 end), [
          flaky_tool(2)
        ])

      elapsed = time(fn -> LangEx.invoke(graph, opening()) end)

      assert 3 == attempts()
      assert elapsed >= 60
    end
  end

  describe "propagating errors" do
    test "an exhausted retry re-raises when the agent lets tool errors through" do
      answers_then_stops()

      graph =
        Prebuilt.agent(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          tools: [flaky_tool(99)],
          tool_opts: [handle_tool_errors: false],
          middleware: [ToolRetry.new(max_attempts: 2)]
        )

      assert {:error, %LangEx.NodeError{node: :tools}} = LangEx.invoke(graph, opening())
      assert 2 == attempts()
    end
  end

  defp agent(middleware, tools) do
    Prebuilt.agent(
      provider: LangEx.LLM.OpenAI,
      model: "gpt-4o",
      tools: tools,
      middleware: [middleware]
    )
  end

  # First call asks for the tool, the second closes the conversation.
  defp answers_then_stops do
    counter = :counters.new(1, [])

    stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
      :counters.add(counter, 1, 1)

      counter
      |> :counters.get(1)
      |> model_reply()
    end)
  end

  defp model_reply(1) do
    {:ok,
     Message.ai(nil,
       id: "ai-1",
       tool_calls: [%Message.ToolCall{name: "metrics", id: "call-1", args: %{}}]
     ), usage()}
  end

  defp model_reply(_n), do: {:ok, Message.ai("done"), usage()}

  defp usage, do: %{input_tokens: 1, output_tokens: 1}

  defp opening, do: %{messages: [Message.human("check metrics")]}

  defp tool_reply(result), do: Enum.find(result.messages, &match?(%Message.Tool{}, &1))

  # Attempts are counted in an ETS-backed counter because each tool call runs
  # in its own task, so the count has to outlive the process making it.
  defp flaky_tool(failures) do
    counter = :counters.new(1, [])
    :persistent_term.put({__MODULE__, self()}, counter)

    %Tool{
      name: "metrics",
      description: "read metrics",
      parameters: %{},
      function: fn _args ->
        :counters.add(counter, 1, 1)

        counter
        |> :counters.get(1)
        |> respond(failures)
      end
    }
  end

  defp respond(attempt, failures) when attempt <= failures, do: raise("still down")
  defp respond(_attempt, _failures), do: "metrics"

  defp attempts do
    {__MODULE__, self()}
    |> :persistent_term.get()
    |> :counters.get(1)
  end

  defp time(fun) do
    start = System.monotonic_time(:millisecond)
    fun.()
    System.monotonic_time(:millisecond) - start
  end
end
