defmodule LangEx.Middleware.RubricTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Message
  alias LangEx.Middleware
  alias LangEx.Middleware.Rubric

  describe "after_model gate" do
    test "bounces an inadequate answer back with feedback and a model jump" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        call = %Message.ToolCall{
          name: "respond",
          id: "r1",
          args: %{"passes" => false, "feedback" => "cite the logs"}
        }

        {:ok, Message.ai(nil, tool_calls: [call]), %{input_tokens: 1, output_tokens: 1}}
      end)

      mw = Rubric.new(provider: LangEx.LLM.OpenAI, model: "gpt-4o", rubric: "cites logs")

      state = %{messages: [Message.ai("no citation")], rubric_attempts: 0}
      update = mw.after_model.(state)

      assert update[Middleware.jump_key()] == :model
      assert update.rubric_attempts == 1
      assert [%Message.Human{content: "[Completion check failed]" <> _}] = update.messages
    end

    test "passes an adequate answer through untouched" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        call = %Message.ToolCall{name: "respond", id: "r1", args: %{"passes" => true}}
        {:ok, Message.ai(nil, tool_calls: [call]), %{input_tokens: 1, output_tokens: 1}}
      end)

      mw = Rubric.new(provider: LangEx.LLM.OpenAI, model: "gpt-4o", rubric: "cites logs")

      state = %{messages: [Message.ai("here are the logs...")], rubric_attempts: 0}

      assert %{} == mw.after_model.(state)
    end

    test "accepts the answer once max_attempts is exhausted" do
      mw =
        Rubric.new(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          rubric: "cites logs",
          max_attempts: 1
        )

      state = %{messages: [Message.ai("still weak")], rubric_attempts: 1}

      assert %{} == mw.after_model.(state)
    end

    test "does not gate while the agent is still calling tools" do
      mw = Rubric.new(provider: LangEx.LLM.OpenAI, model: "gpt-4o", rubric: "cites logs")

      call = %Message.ToolCall{name: "look", id: "c1", args: %{}}
      state = %{messages: [Message.ai(nil, tool_calls: [call])], rubric_attempts: 0}

      assert %{} == mw.after_model.(state)
    end
  end
end
