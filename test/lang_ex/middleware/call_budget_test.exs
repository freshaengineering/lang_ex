defmodule LangEx.Middleware.CallBudgetTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Message
  alias LangEx.Middleware
  alias LangEx.Middleware.CallBudget
  alias LangEx.Prebuilt
  alias LangEx.Tool

  describe "model call budget" do
    test "a run that would loop forever stops at its allowance" do
      counter = always_calls_a_tool()
      graph = agent(CallBudget.new(max_model_calls: 3), [ping_tool()])

      {:ok, result} = LangEx.invoke(graph, opening())

      assert 3 == :counters.get(counter, 1)
      assert %{budget_exhausted: true, model_calls: 3} = result
    end

    test "a run finishing inside its allowance is untouched" do
      answers("all done")
      graph = agent(CallBudget.new(max_model_calls: 5))

      {:ok, result} = LangEx.invoke(graph, opening())

      assert %{budget_exhausted: false, model_calls: 1} = result
      assert %Message.AI{content: "all done"} = List.last(result.messages)
    end

    test "the tool calls left hanging by the stop are answered" do
      always_calls_a_tool()
      graph = agent(CallBudget.new(max_model_calls: 1), [ping_tool()])

      {:ok, result} = LangEx.invoke(graph, opening())

      refute_received {:ran, _args}

      assert %Message.Tool{status: :error, content: content} =
               Enum.find(result.messages, &match?(%Message.Tool{}, &1))

      assert content =~ "model call budget of 1"
    end
  end

  describe "token budget" do
    test "a run stops once it has spent its tokens" do
      counter = always_calls_a_tool(usage(400))
      graph = agent(CallBudget.new(max_tokens: 1000), [ping_tool()])

      {:ok, result} = LangEx.invoke(graph, opening())

      assert 2 == :counters.get(counter, 1)
      assert result.budget_exhausted
    end

    test "the reason names the limit that was hit" do
      always_calls_a_tool(usage(5000))
      graph = agent(CallBudget.new(max_model_calls: 50, max_tokens: 1000), [ping_tool()])

      {:ok, result} = LangEx.invoke(graph, opening())

      assert %Message.Tool{content: content} =
               Enum.find(result.messages, &match?(%Message.Tool{}, &1))

      assert content =~ "token budget of 1000"
    end
  end

  describe "composition" do
    test "the budget outranks another middleware asking for another pass" do
      counter = answers("thinking")

      looper =
        Middleware.new(
          name: :looper,
          after_model: fn _state -> %{Middleware.jump_key() => :model} end
        )

      graph =
        Prebuilt.agent(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          middleware: [CallBudget.new(max_model_calls: 2), looper]
        )

      {:ok, result} = LangEx.invoke(graph, opening())

      assert 2 == :counters.get(counter, 1)
      assert %{budget_exhausted: true, model_calls: 2} = result
    end
  end

  defp agent(middleware, tools \\ []) do
    Prebuilt.agent(
      provider: LangEx.LLM.OpenAI,
      model: "gpt-4o",
      tools: tools,
      middleware: [middleware]
    )
  end

  # A model that always asks for the same tool never terminates on its own,
  # which is exactly the runaway a budget exists to bound.
  defp always_calls_a_tool(usage \\ usage(1)) do
    counter = :counters.new(1, [])

    stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
      :counters.add(counter, 1, 1)
      {:ok, tool_request(:counters.get(counter, 1)), usage}
    end)

    counter
  end

  defp answers(content) do
    counter = :counters.new(1, [])

    stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
      :counters.add(counter, 1, 1)
      {:ok, Message.ai(content), usage(1)}
    end)

    counter
  end

  defp tool_request(n) do
    Message.ai(nil,
      id: "ai-#{n}",
      tool_calls: [%Message.ToolCall{name: "ping", id: "call-#{n}", args: %{}}]
    )
  end

  defp usage(n), do: %{input_tokens: n, output_tokens: n}

  defp opening, do: %{messages: [Message.human("go")]}

  defp ping_tool do
    test_pid = self()

    %Tool{
      name: "ping",
      description: "pings something",
      parameters: %{},
      function: fn args ->
        send(test_pid, {:ran, args})
        "pong"
      end
    }
  end
end
