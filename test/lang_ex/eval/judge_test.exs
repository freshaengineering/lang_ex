defmodule LangEx.Eval.JudgeTest do
  use ExUnit.Case, async: true
  use Mimic

  alias LangEx.Eval.Judge
  alias LangEx.Message

  test "scores a trajectory step list against the criteria" do
    stub(LangEx.LLM.Anthropic, :chat_with_usage, fn messages, _opts ->
      assert [%Message.System{content: system}, %Message.Human{content: prompt}] = messages
      assert system =~ "expert evaluator of agent tool-use trajectories"
      assert prompt =~ "resolve the incident with minimal calls"
      assert prompt =~ ~s|1. search({"q":"elixir"})|
      assert prompt =~ ~s|2. fetch({"id":1})|

      call = %Message.ToolCall{
        name: "respond",
        id: "r1",
        args: %{"score" => 0.8, "reasoning" => "efficient trajectory"}
      }

      {:ok, Message.ai(nil, tool_calls: [call]), %{input_tokens: 1, output_tokens: 1}}
    end)

    steps = [
      %{name: "search", args: %{"q" => "elixir"}},
      %{name: "fetch", args: %{"id" => 1}}
    ]

    assert {:ok, %{score: 0.8, reasoning: "efficient trajectory"}} =
             Judge.run(steps,
               model: "claude-sonnet-4-20250514",
               criteria: "resolve the incident with minimal calls"
             )
  end

  test "renders a message history as a compact trimmed transcript" do
    stub(LangEx.LLM.Anthropic, :chat_with_usage, fn messages, _opts ->
      assert [_system, %Message.Human{content: prompt}] = messages
      assert prompt =~ "Human: check the weather in Paris"
      assert prompt =~ ~s|-> tool call get_weather({"city":"Paris"})|
      assert prompt =~ "AI: " <> String.duplicate("x", 500) <> "…"
      refute prompt =~ String.duplicate("x", 501)
      assert prompt =~ "Tool result: " <> String.duplicate("y", 200) <> "…"
      refute prompt =~ String.duplicate("y", 201)

      call = %Message.ToolCall{
        name: "respond",
        id: "r1",
        args: %{"score" => 1, "reasoning" => "single focused call"}
      }

      {:ok, Message.ai(nil, tool_calls: [call]), %{input_tokens: 1, output_tokens: 1}}
    end)

    messages = [
      Message.human("check the weather in Paris"),
      Message.ai(String.duplicate("x", 600),
        tool_calls: [
          %Message.ToolCall{name: "get_weather", id: "c1", args: %{"city" => "Paris"}}
        ]
      ),
      Message.tool(String.duplicate("y", 250), "c1"),
      Message.ai("Paris is sunny.")
    ]

    assert {:ok, %{score: score, reasoning: "single focused call"}} =
             Judge.run(messages, model: "claude-sonnet-4-20250514")

    assert score == 1.0
  end

  test "returns the provider error unchanged" do
    stub(LangEx.LLM.Anthropic, :chat_with_usage, fn _messages, _opts ->
      {:error, :timeout}
    end)

    assert {:error, :timeout} =
             Judge.run([%{name: "search", args: %{}}], model: "claude-sonnet-4-20250514")
  end

  test "rejects a verdict whose score is not a number" do
    stub(LangEx.LLM.Anthropic, :chat_with_usage, fn _messages, _opts ->
      call = %Message.ToolCall{
        name: "respond",
        id: "r1",
        args: %{"score" => "high", "reasoning" => "vibes"}
      }

      {:ok, Message.ai(nil, tool_calls: [call]), %{input_tokens: 1, output_tokens: 1}}
    end)

    assert {:error, :invalid_judge_output} =
             Judge.run([%{name: "search", args: %{}}], model: "claude-sonnet-4-20250514")
  end
end
