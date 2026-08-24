defmodule LangEx.Middleware.ModelFallbackTest do
  use ExUnit.Case, async: true
  use Mimic

  alias LangEx.Message
  alias LangEx.Middleware.ModelFallback
  alias LangEx.Middleware.ModelRequest
  alias LangEx.Tool

  @moduletag :capture_log

  describe "wrap_model_call" do
    test "returns the primary update untouched when the primary call succeeds" do
      test_pid = self()

      stub(LangEx.LLM.Anthropic, :chat_with_usage, fn _messages, _opts ->
        send(test_pid, :fallback_called)
        {:ok, Message.ai("fallback"), %{input_tokens: 1, output_tokens: 1}}
      end)

      middleware = ModelFallback.new(models: ["claude-sonnet-5"])

      request =
        ModelRequest.new(
          messages: [Message.human("hi")],
          tools: [],
          state: %{messages: [Message.human("hi")], llm_usage: %{}}
        )

      update =
        middleware.wrap_model_call.(request, fn _request ->
          %{messages: [Message.ai("primary")], llm_usage: %{input_tokens: 2, output_tokens: 2}}
        end)

      assert %{messages: [%Message.AI{content: "primary"}]} = update
      refute_received :fallback_called
    end

    test "answers from the first fallback model when the primary call raises" do
      expect(LangEx.LLM.Anthropic, :chat_with_usage, fn messages, opts ->
        assert [%Message.Human{content: "hi"}] = messages
        assert opts[:model] == "claude-sonnet-5"
        assert [%Tool{name: "logs"}] = opts[:tools]
        assert opts[:temperature] == 0.2
        {:ok, Message.ai("fallback answer"), %{input_tokens: 3, output_tokens: 5}}
      end)

      middleware =
        ModelFallback.new(models: ["claude-sonnet-5"], llm_opts: [temperature: 0.2])

      request =
        ModelRequest.new(
          messages: [Message.human("hi")],
          tools: [%Tool{name: "logs", description: "read logs", parameters: %{}}],
          state: %{messages: [Message.human("hi")], llm_usage: %{}}
        )

      update = middleware.wrap_model_call.(request, fn _request -> raise "provider down" end)

      assert %{
               messages: [%Message.AI{content: "fallback answer"}],
               llm_usage: %{input_tokens: 3, output_tokens: 5}
             } = update
    end

    test "falls through to the second fallback when the first also fails" do
      expect(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, opts ->
        assert opts[:model] == "gpt-5"
        {:error, {503, "unavailable"}}
      end)

      expect(LangEx.LLM.Anthropic, :chat_with_usage, fn _messages, opts ->
        assert opts[:model] == "claude-sonnet-5"
        {:ok, Message.ai("second fallback"), %{input_tokens: 1, output_tokens: 1}}
      end)

      middleware =
        ModelFallback.new(models: [{LangEx.LLM.OpenAI, "gpt-5"}, "claude-sonnet-5"])

      request =
        ModelRequest.new(
          messages: [Message.human("hi")],
          tools: [],
          state: %{messages: [Message.human("hi")], llm_usage: %{}}
        )

      update = middleware.wrap_model_call.(request, fn _request -> raise "provider down" end)

      assert %{messages: [%Message.AI{content: "second fallback"}]} = update
    end

    test "re-raises the original primary failure when every fallback fails" do
      expect(LangEx.LLM.Anthropic, :chat_with_usage, fn _messages, _opts ->
        {:error, {529, "overloaded"}}
      end)

      middleware = ModelFallback.new(models: ["claude-sonnet-5"])

      request =
        ModelRequest.new(
          messages: [Message.human("hi")],
          tools: [],
          state: %{messages: [Message.human("hi")], llm_usage: %{}}
        )

      assert_raise RuntimeError, "primary down", fn ->
        middleware.wrap_model_call.(request, fn _request -> raise "primary down" end)
      end
    end

    test "propagates the failure untouched when no fallback models are configured" do
      middleware = ModelFallback.new(models: [])

      request =
        ModelRequest.new(
          messages: [Message.human("hi")],
          tools: [],
          state: %{messages: [Message.human("hi")], llm_usage: %{}}
        )

      assert_raise RuntimeError, "primary down", fn ->
        middleware.wrap_model_call.(request, fn _request -> raise "primary down" end)
      end
    end
  end
end
