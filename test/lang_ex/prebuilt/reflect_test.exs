defmodule LangEx.Prebuilt.ReflectTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Message
  alias LangEx.Prebuilt
  alias LangEx.Tool

  describe "reflect/1" do
    test "stops on the first approving critique" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, opts ->
        case opts[:tools] do
          [%Tool{name: "respond"}] ->
            call = %Message.ToolCall{name: "respond", id: "r", args: %{"approved" => true}}
            {:ok, Message.ai(nil, tool_calls: [call]), %{input_tokens: 1, output_tokens: 1}}

          _ ->
            {:ok, Message.ai("Draft answer"), %{input_tokens: 2, output_tokens: 2}}
        end
      end)

      graph =
        Prebuilt.reflect(provider: LangEx.LLM.OpenAI, model: "gpt-4o", generate_prompt: "draft")

      {:ok, result} = LangEx.invoke(graph, %{messages: [Message.human("q")]})

      assert result.reflect_approved
      assert result.reflect_iteration == 1
      assert Enum.any?(result.messages, &match?(%Message.AI{content: "Draft answer"}, &1))
    end

    test "revises until the critic approves" do
      counter = :counters.new(1, [:atomics])

      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, opts ->
        case opts[:tools] do
          [%Tool{name: "respond"}] ->
            :counters.add(counter, 1, 1)
            approved = :counters.get(counter, 1) >= 2

            call = %Message.ToolCall{
              name: "respond",
              id: "r",
              args: %{"approved" => approved, "feedback" => "add detail"}
            }

            {:ok, Message.ai(nil, tool_calls: [call]), %{input_tokens: 1, output_tokens: 1}}

          _ ->
            {:ok, Message.ai("Draft"), %{input_tokens: 1, output_tokens: 1}}
        end
      end)

      graph = Prebuilt.reflect(provider: LangEx.LLM.OpenAI, model: "gpt-4o", max_iterations: 5)
      {:ok, result} = LangEx.invoke(graph, %{messages: [Message.human("q")]})

      assert result.reflect_approved
      assert result.reflect_iteration == 2

      assert Enum.any?(
               result.messages,
               &match?(%Message.Human{content: "[Reviewer feedback]" <> _}, &1)
             )
    end

    test "stops at max_iterations without approval" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, opts ->
        case opts[:tools] do
          [%Tool{name: "respond"}] ->
            call = %Message.ToolCall{
              name: "respond",
              id: "r",
              args: %{"approved" => false, "feedback" => "more"}
            }

            {:ok, Message.ai(nil, tool_calls: [call]), %{input_tokens: 1, output_tokens: 1}}

          _ ->
            {:ok, Message.ai("Draft"), %{input_tokens: 1, output_tokens: 1}}
        end
      end)

      graph = Prebuilt.reflect(provider: LangEx.LLM.OpenAI, model: "gpt-4o", max_iterations: 2)
      {:ok, result} = LangEx.invoke(graph, %{messages: [Message.human("q")]})

      refute result.reflect_approved
      assert result.reflect_iteration == 2
    end
  end
end
