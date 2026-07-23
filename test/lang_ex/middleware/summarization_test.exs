defmodule LangEx.Middleware.SummarizationTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Message
  alias LangEx.Middleware.Summarization

  describe "before_model hook" do
    test "leaves history untouched when under budget" do
      mw = Summarization.new(provider: LangEx.LLM.OpenAI, model: "gpt-4o", max_bytes: 1_000_000)

      assert %{} == mw.before_model.(%{messages: [Message.human("small")]})
    end

    test "rewrites older history into a persisted summary" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("DENSE SUMMARY"), %{input_tokens: 5, output_tokens: 3}}
      end)

      messages = [
        Message.human(String.duplicate("q1 ", 50)),
        Message.ai(String.duplicate("a1 ", 50)),
        Message.human(String.duplicate("q2 ", 50)),
        Message.ai(String.duplicate("a2 ", 50)),
        Message.human("recent question"),
        Message.ai("recent answer")
      ]

      mw =
        Summarization.new(provider: LangEx.LLM.OpenAI, model: "gpt-4o", max_bytes: 100, keep: 2)

      update = mw.before_model.(%{messages: messages})

      assert [%Message.RemoveMessage{} | rest] = update.messages
      assert Enum.any?(rest, &match?(%Message.Human{content: "[Summary" <> _}, &1))
      assert Enum.any?(rest, &match?(%Message.Human{content: "recent question"}, &1))
      assert List.last(rest) == %Message.AI{content: "recent answer", tool_calls: []}
      assert %{input_tokens: 5, output_tokens: 3} = update.llm_usage
    end

    test "keeps a tool result attached to its originating tool call" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("SUMMARY"), %{input_tokens: 1, output_tokens: 1}}
      end)

      call = %Message.ToolCall{name: "look", id: "c1", args: %{}}

      messages = [
        Message.human(String.duplicate("old ", 50)),
        Message.ai(String.duplicate("old ", 50)),
        Message.ai(String.duplicate("x ", 50), tool_calls: [call]),
        Message.tool("tool output", "c1")
      ]

      mw =
        Summarization.new(provider: LangEx.LLM.OpenAI, model: "gpt-4o", max_bytes: 100, keep: 1)

      update = mw.before_model.(%{messages: messages})
      kept = tl(update.messages)

      assert Enum.any?(kept, &match?(%Message.AI{tool_calls: [%{id: "c1"}]}, &1))
      assert Enum.any?(kept, &match?(%Message.Tool{tool_call_id: "c1"}, &1))
    end
  end
end
