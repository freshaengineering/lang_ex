defmodule LangEx.LLM.ResilientTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Message

  describe "chat_with_usage/3" do
    test "returns AI message with usage on success" do
      stub(LangEx.LLM.Anthropic, :chat_with_usage, fn _msgs, _opts ->
        {:ok, Message.ai("hello"), %{input_tokens: 10, output_tokens: 5}}
      end)

      assert {:ok, %Message.AI{content: "hello"}, usage} =
               LangEx.LLM.Resilient.chat_with_usage(
                 LangEx.LLM.Anthropic,
                 [Message.human("hi")],
                 api_key: "test"
               )

      assert usage.input_tokens == 10
      assert is_integer(usage.duration_ms)
    end

    test "retries on retryable errors" do
      call_count = :counters.new(1, [:atomics])

      stub(LangEx.LLM.Anthropic, :chat_with_usage, fn _msgs, _opts ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case n do
          0 -> {:error, {429, %{"error" => "rate limited"}}}
          _ -> {:ok, Message.ai("recovered"), %{input_tokens: 5, output_tokens: 3}}
        end
      end)

      assert {:ok, %Message.AI{content: "recovered"}, _usage} =
               LangEx.LLM.Resilient.chat_with_usage(
                 LangEx.LLM.Anthropic,
                 [Message.human("hi")],
                 api_key: "test",
                 max_retries: 2,
                 retry_base_ms: 1
               )
    end

    test "retries with the caller's provider opts intact" do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      stub(LangEx.LLM.Anthropic, :chat_with_usage, fn _msgs, opts ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        send(test_pid, {:call_opts, n, opts})

        case n do
          0 -> {:error, {429, %{"error" => "rate limited"}}}
          _ -> {:ok, Message.ai("recovered"), %{input_tokens: 5, output_tokens: 3}}
        end
      end)

      tool = %LangEx.Tool{name: "respond", description: "d", parameters: %{}}

      assert {:ok, %Message.AI{content: "recovered"}, _usage} =
               LangEx.LLM.Resilient.chat_with_usage(
                 LangEx.LLM.Anthropic,
                 [Message.human("hi")],
                 api_key: "test",
                 model: "claude-sonnet-5",
                 tools: [tool],
                 max_tokens: 1024,
                 max_retries: 2,
                 retry_base_ms: 1
               )

      assert_receive {:call_opts, 1, retry_opts}
      assert retry_opts[:model] == "claude-sonnet-5"
      assert retry_opts[:tools] == [tool]
      assert retry_opts[:max_tokens] == 1024
      assert retry_opts[:api_key] == "test"
    end

    test "calls fallback on final failure" do
      stub(LangEx.LLM.Anthropic, :chat_with_usage, fn _msgs, _opts ->
        {:error, {500, "server error"}}
      end)

      fallback = fn -> Message.ai("fallback response") end

      assert {:ok, %Message.AI{content: "fallback response"}, _usage} =
               LangEx.LLM.Resilient.chat_with_usage(
                 LangEx.LLM.Anthropic,
                 [Message.human("hi")],
                 api_key: "test",
                 max_retries: 0,
                 fallback: fallback
               )
    end

    test "returns error when no fallback and non-retryable" do
      stub(LangEx.LLM.Anthropic, :chat_with_usage, fn _msgs, _opts ->
        {:error, {400, "bad request"}}
      end)

      assert {:error, {400, "bad request"}} =
               LangEx.LLM.Resilient.chat_with_usage(
                 LangEx.LLM.Anthropic,
                 [Message.human("hi")],
                 api_key: "test",
                 max_retries: 3
               )
    end

    test "invokes on_success callback" do
      stub(LangEx.LLM.Anthropic, :chat_with_usage, fn _msgs, _opts ->
        {:ok, Message.ai("ok"), %{input_tokens: 1, output_tokens: 1}}
      end)

      test_pid = self()

      on_success = fn attempt, duration_ms, _ai, _usage ->
        send(test_pid, {:success, attempt, duration_ms})
      end

      LangEx.LLM.Resilient.chat_with_usage(
        LangEx.LLM.Anthropic,
        [Message.human("hi")],
        api_key: "test",
        on_success: on_success
      )

      assert_receive {:success, 0, duration_ms} when is_integer(duration_ms)
    end

    test "invokes on_retry callback" do
      call_count = :counters.new(1, [:atomics])

      stub(LangEx.LLM.Anthropic, :chat_with_usage, fn _msgs, _opts ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case n do
          0 -> {:error, {429, "rate limited"}}
          _ -> {:ok, Message.ai("ok"), %{input_tokens: 1, output_tokens: 1}}
        end
      end)

      test_pid = self()

      on_retry = fn attempt, _duration_ms, _wait_ms, reason ->
        send(test_pid, {:retry, attempt, reason})
      end

      LangEx.LLM.Resilient.chat_with_usage(
        LangEx.LLM.Anthropic,
        [Message.human("hi")],
        api_key: "test",
        max_retries: 2,
        retry_base_ms: 1,
        on_retry: on_retry
      )

      assert_receive {:retry, 0, {429, "rate limited"}}
    end

    test "falls back to chat/2 for providers without chat_with_usage" do
      defmodule SimpleProvider do
        @behaviour LangEx.LLM

        @impl true
        def chat(_messages, _opts) do
          {:ok, LangEx.Message.ai("simple")}
        end
      end

      assert {:ok, %Message.AI{content: "simple"}, usage} =
               LangEx.LLM.Resilient.chat_with_usage(
                 SimpleProvider,
                 [Message.human("hi")],
                 []
               )

      assert usage.input_tokens == 0
    end
  end

  describe "chat/3" do
    test "returns just the AI message" do
      stub(LangEx.LLM.Anthropic, :chat_with_usage, fn _msgs, _opts ->
        {:ok, Message.ai("hello"), %{input_tokens: 10, output_tokens: 5}}
      end)

      assert {:ok, %Message.AI{content: "hello"}} =
               LangEx.LLM.Resilient.chat(
                 LangEx.LLM.Anthropic,
                 [Message.human("hi")],
                 api_key: "test"
               )
    end
  end

  describe "default_retryable?/1" do
    test "429 is retryable" do
      assert LangEx.LLM.Resilient.default_retryable?({429, "rate limited"})
    end

    test "500+ is retryable" do
      assert LangEx.LLM.Resilient.default_retryable?({500, "server error"})
      assert LangEx.LLM.Resilient.default_retryable?({502, "bad gateway"})
    end

    test "400 is not retryable" do
      refute LangEx.LLM.Resilient.default_retryable?({400, "bad request"})
    end

    test "random errors are not retryable" do
      refute LangEx.LLM.Resilient.default_retryable?(:timeout)
    end
  end

  describe "format_error/1" do
    test "formats HTTP errors with message" do
      assert "HTTP 429: rate limited" =
               LangEx.LLM.Resilient.format_error(
                 {429, %{"error" => %{"message" => "rate limited"}}}
               )
    end

    test "formats HTTP errors with body" do
      result = LangEx.LLM.Resilient.format_error({500, "server error"})
      assert String.starts_with?(result, "HTTP 500:")
    end
  end
end
