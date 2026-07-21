defmodule LangEx.LLM.ChatModelTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.LLM.ChatModel
  alias LangEx.Graph
  alias LangEx.Message
  alias LangEx.Tool

  describe "ChatModel node with mocked LLM" do
    test "OpenAI-backed node appends AI response to message history" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("I'm GPT, nice to meet you!"), %{input_tokens: 10, output_tokens: 5}}
      end)

      {:ok, result} =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(:llm, ChatModel.node(provider: LangEx.LLM.OpenAI, model: "gpt-4o"))
        |> Graph.add_edge(:__start__, :llm)
        |> Graph.add_edge(:llm, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{messages: [Message.human("Hello GPT")]})

      assert %{
               messages: [
                 %Message.Human{content: "Hello GPT"},
                 %Message.AI{content: "I'm GPT, nice to meet you!"}
               ]
             } = result
    end

    test "Anthropic-backed node appends AI response to message history" do
      stub(LangEx.LLM.Anthropic, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("I'm Claude, happy to help!"), %{input_tokens: 10, output_tokens: 5}}
      end)

      {:ok, result} =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(:llm, ChatModel.node(provider: LangEx.LLM.Anthropic))
        |> Graph.add_edge(:__start__, :llm)
        |> Graph.add_edge(:llm, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{
          messages: [Message.system("Be helpful"), Message.human("Hello Claude")]
        })

      assert %{
               messages: [
                 %Message.System{content: "Be helpful"},
                 %Message.Human{content: "Hello Claude"},
                 %Message.AI{content: "I'm Claude, happy to help!"}
               ]
             } = result
    end

    test "Gemini-backed node appends AI response to message history" do
      stub(LangEx.LLM.Gemini, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("I'm Gemini, ready to help!"), %{input_tokens: 10, output_tokens: 5}}
      end)

      {:ok, result} =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(:llm, ChatModel.node(model: "gemini-2.5-flash"))
        |> Graph.add_edge(:__start__, :llm)
        |> Graph.add_edge(:llm, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{messages: [Message.human("Hello Gemini")]})

      assert %{
               messages: [
                 %Message.Human{content: "Hello Gemini"},
                 %Message.AI{content: "I'm Gemini, ready to help!"}
               ]
             } = result
    end

    test "token usage accumulates in state when the schema declares a usage key" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("hi"), %{input_tokens: 100, output_tokens: 20}}
      end)

      {:ok, result} =
        Graph.new(
          messages: {[], &Message.add_messages/2},
          llm_usage: {%{}, &ChatModel.merge_usage/2},
          turns: {0, fn _old, new -> new end}
        )
        |> Graph.add_node(
          :llm,
          ChatModel.node(provider: LangEx.LLM.OpenAI, model: "gpt-4o")
        )
        |> Graph.add_node(:count, fn state -> %{turns: state.turns + 1} end)
        |> Graph.add_edge(:__start__, :llm)
        |> Graph.add_edge(:llm, :count)
        |> Graph.add_conditional_edges(:count, fn
          %{turns: t} when t >= 2 -> :__end__
          _ -> :llm
        end)
        |> Graph.compile()
        |> LangEx.invoke(%{messages: [Message.human("Hello")]})

      assert %{llm_usage: %{input_tokens: 200, output_tokens: 40}} = result
    end

    test "usage is not written to state without a declared usage key" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("hi"), %{input_tokens: 100, output_tokens: 20}}
      end)

      {:ok, result} =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(:llm, ChatModel.node(provider: LangEx.LLM.OpenAI, model: "gpt-4o"))
        |> Graph.add_edge(:__start__, :llm)
        |> Graph.add_edge(:llm, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{messages: [Message.human("Hello")]})

      refute Map.has_key?(result, :llm_usage)
    end

    test "providers without chat_with_usage still work through chat/2" do
      defmodule BareProvider do
        @behaviour LangEx.LLM

        @impl true
        def chat(_messages, _opts), do: {:ok, LangEx.Message.ai("bare response")}
      end

      {:ok, result} =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(:llm, ChatModel.node(provider: BareProvider, model: "bare-1"))
        |> Graph.add_edge(:__start__, :llm)
        |> Graph.add_edge(:llm, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{messages: [Message.human("Hello")]})

      assert %{messages: [_, %Message.AI{content: "bare response"}]} = result
    end

    test "multi-turn conversation with LLM node in a loop" do
      call_count = :counters.new(1, [:atomics])

      stub(LangEx.LLM.OpenAI, :chat, fn _messages, _opts ->
        n = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, n)
        {:ok, Message.ai("Response #{n}")}
      end)

      {:ok, result} =
        Graph.new(
          messages: {[], &Message.add_messages/2},
          turns: {0, fn _old, new -> new end}
        )
        |> Graph.add_node(:llm, fn state ->
          {:ok, ai_msg} = LangEx.LLM.OpenAI.chat(state.messages, [])
          %{messages: [ai_msg], turns: state.turns + 1}
        end)
        |> Graph.add_edge(:__start__, :llm)
        |> Graph.add_conditional_edges(:llm, fn
          %{turns: t} when t >= 3 -> :__end__
          _ -> :llm
        end)
        |> Graph.compile()
        |> LangEx.invoke(%{messages: [Message.human("Start")]})

      assert %{
               turns: 3,
               messages: [
                 %Message.Human{content: "Start"},
                 %Message.AI{content: "Response 1"},
                 %Message.AI{content: "Response 2"},
                 %Message.AI{content: "Response 3"}
               ]
             } = result
    end
  end

  describe "structured_node/1" do
    test "decodes the respond tool call into the target key and appends clean JSON" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        call = %Message.ToolCall{
          name: "respond",
          id: "r1",
          args: %{"sentiment" => "positive", "score" => 0.9}
        }

        {:ok, Message.ai(nil, tool_calls: [call]), %{input_tokens: 5, output_tokens: 2}}
      end)

      node =
        ChatModel.structured_node(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          into: :analysis,
          schema: %{type: "object", properties: %{sentiment: %{type: "string"}}}
        )

      result = node.(%{messages: [Message.human("I love it")]})

      assert %{analysis: %{"sentiment" => "positive", "score" => 0.9}} = result
      assert [%Message.AI{content: content}] = result.messages
      assert Jason.decode!(content) == %{"sentiment" => "positive", "score" => 0.9}
    end

    test "falls back to decoding JSON from the text response" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai(~s({"ok": true})), %{input_tokens: 1, output_tokens: 1}}
      end)

      node =
        ChatModel.structured_node(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          schema: %{type: "object"}
        )

      assert %{structured: %{"ok" => true}} = node.(%{messages: [Message.human("hi")]})
    end

    test "non-JSON prose yields a nil structured value and keeps the message" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("just prose"), %{input_tokens: 1, output_tokens: 1}}
      end)

      node =
        ChatModel.structured_node(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          schema: %{type: "object"}
        )

      assert %{structured: nil, messages: [%Message.AI{content: "just prose"}]} =
               node.(%{messages: [Message.human("hi")]})
    end

    test "a non-respond tool call yields nil" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        call = %Message.ToolCall{name: "other", id: "o1", args: %{}}
        {:ok, Message.ai("here you go", tool_calls: [call]), %{input_tokens: 1, output_tokens: 1}}
      end)

      node =
        ChatModel.structured_node(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          schema: %{type: "object"}
        )

      assert %{structured: nil} = node.(%{messages: [Message.human("hi")]})
    end

    test "an empty response yields nil and an empty message" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai(nil), %{input_tokens: 1, output_tokens: 1}}
      end)

      node =
        ChatModel.structured_node(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          schema: %{type: "object"}
        )

      assert %{structured: nil, messages: [%Message.AI{content: ""}]} =
               node.(%{messages: [Message.human("hi")]})
    end

    test "a provider error is surfaced" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts -> {:error, :boom} end)

      node =
        ChatModel.structured_node(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          schema: %{type: "object"}
        )

      assert_raise RuntimeError, ~r/structured output request failed/, fn ->
        node.(%{messages: [Message.human("hi")]})
      end
    end
  end

  describe "structured/2" do
    test "returns {:ok, data} from the respond tool call when required keys are present" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, opts ->
        assert [%Tool{name: "respond"}] = opts[:tools]

        call = %Message.ToolCall{
          name: "respond",
          id: "r1",
          args: %{"action" => "investigate", "actionable" => true}
        }

        {:ok, Message.ai(nil, tool_calls: [call]), %{input_tokens: 1, output_tokens: 1}}
      end)

      schema = %{
        type: "object",
        properties: %{action: %{type: "string"}, actionable: %{type: "boolean"}},
        required: ["action", "actionable"]
      }

      assert {:ok, %{"action" => "investigate", "actionable" => true}} =
               ChatModel.structured([Message.human("classify")],
                 provider: LangEx.LLM.OpenAI,
                 model: "gpt-4o",
                 schema: schema
               )
    end

    test "falls back to decoding JSON content" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai(~s({"action": "skip"})), %{input_tokens: 1, output_tokens: 1}}
      end)

      assert {:ok, %{"action" => "skip"}} =
               ChatModel.structured([Message.human("hi")],
                 provider: LangEx.LLM.OpenAI,
                 model: "gpt-4o",
                 schema: %{type: "object", required: ["action"]}
               )
    end

    test "reports missing required keys" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai(~s({"action": "skip"})), %{input_tokens: 1, output_tokens: 1}}
      end)

      assert {:error, {:missing_required, ["actionable"]}} =
               ChatModel.structured([Message.human("hi")],
                 provider: LangEx.LLM.OpenAI,
                 model: "gpt-4o",
                 schema: %{type: "object", required: ["action", "actionable"]}
               )
    end

    test "reports no structured output for prose" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("just prose"), %{input_tokens: 1, output_tokens: 1}}
      end)

      assert {:error, :no_structured_output} =
               ChatModel.structured([Message.human("hi")],
                 provider: LangEx.LLM.OpenAI,
                 model: "gpt-4o",
                 schema: %{type: "object"}
               )
    end

    test "surfaces provider errors" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts -> {:error, :boom} end)

      assert {:error, :boom} =
               ChatModel.structured([Message.human("hi")],
                 provider: LangEx.LLM.OpenAI,
                 model: "gpt-4o",
                 schema: %{type: "object"}
               )
    end
  end
end
