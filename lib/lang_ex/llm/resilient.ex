defmodule LangEx.LLM.Resilient do
  @moduledoc """
  Retry-aware LLM wrapper with backoff, telemetry hooks, and fallback.

  Wraps any `LangEx.LLM` provider with automatic retries on transient
  failures (rate limits, transport errors, server errors), linear backoff,
  and configurable callbacks for observability.

  ## Usage

      LangEx.LLM.Resilient.chat(LangEx.LLM.Anthropic, messages,
        model: "claude-opus-4-6",
        tools: tools,
        max_retries: 3,
        retry_base_ms: 3_000
      )

  ## Options

  All options not listed below are forwarded to the underlying provider.

  - `:max_retries` — maximum retry attempts (default `3`)
  - `:retry_base_ms` — base delay between retries in ms (default `3_000`);
    actual delay is `base * (attempt + 1)` (linear backoff)
  - `:retryable?` — `fn(error_reason) -> boolean()` to classify retryable
    errors (default: 429, transport errors, 5xx)
  - `:on_success` — `fn(attempt, duration_ms, ai, usage) -> any()`
  - `:on_retry` — `fn(attempt, duration_ms, wait_ms, reason) -> any()`
  - `:on_error` — `fn(attempt, duration_ms, reason) -> any()`
  - `:fallback` — `fn() -> Message.AI.t()` called on final failure;
    when `nil`, the error propagates as `{:error, reason}`
  """

  alias LangEx.LLM

  @default_max_retries 3
  @default_retry_base_ms 3_000

  @doc """
  Call the provider with automatic retries. Returns `{:ok, %Message.AI{}}`.

  On final failure, returns the fallback message if configured, or
  `{:error, reason}` if no fallback is set.
  """
  @spec chat(module(), [LLM.message()], keyword()) :: LLM.chat_result()
  def chat(provider, messages, opts) do
    provider
    |> chat_with_usage(messages, opts)
    |> drop_usage()
  end

  defp drop_usage({:ok, ai, _usage}), do: {:ok, ai}
  defp drop_usage({:error, _} = err), do: err

  @doc """
  Like `chat/3` but returns `{:ok, %Message.AI{}, usage_map}` with token
  counts and `:duration_ms`.
  """
  @spec chat_with_usage(module(), [LLM.message()], keyword()) ::
          LLM.chat_with_usage_result() | LLM.chat_result()
  def chat_with_usage(provider, messages, opts) do
    chat_attempt(provider, messages, opts, 0)
  end

  defp chat_attempt(provider, messages, opts, attempt) do
    {config, provider_opts} = split_resilient_opts(opts)
    start = System.monotonic_time(:millisecond)

    provider
    |> call_provider(messages, provider_opts)
    |> handle_chat_result(provider, messages, config, opts, attempt, start)
  end

  defp split_resilient_opts(opts) do
    {max_retries, opts} = Keyword.pop(opts, :max_retries, @default_max_retries)
    {retry_base_ms, opts} = Keyword.pop(opts, :retry_base_ms, @default_retry_base_ms)
    {retryable_fn, opts} = Keyword.pop(opts, :retryable?, &default_retryable?/1)
    {on_success, opts} = Keyword.pop(opts, :on_success)
    {on_retry, opts} = Keyword.pop(opts, :on_retry)
    {on_error, opts} = Keyword.pop(opts, :on_error)
    {fallback, opts} = Keyword.pop(opts, :fallback)

    config = %{
      max_retries: max_retries,
      retry_base_ms: retry_base_ms,
      retryable_fn: retryable_fn,
      on_success: on_success,
      on_retry: on_retry,
      on_error: on_error,
      fallback: fallback
    }

    {config, opts}
  end

  defp handle_chat_result({:ok, ai, usage}, _provider, _messages, config, _opts, attempt, start) do
    elapsed = System.monotonic_time(:millisecond) - start
    invoke_callback(config.on_success, [attempt, elapsed, ai, usage])
    {:ok, ai, Map.put(usage, :duration_ms, elapsed)}
  end

  defp handle_chat_result({:error, reason}, provider, messages, config, opts, attempt, start)
       when attempt < config.max_retries do
    elapsed = System.monotonic_time(:millisecond) - start

    attempt_retry(
      config.retryable_fn.(reason),
      reason,
      provider,
      messages,
      config,
      opts,
      attempt,
      elapsed
    )
  end

  defp handle_chat_result({:error, reason}, _provider, _messages, config, _opts, attempt, start) do
    elapsed = System.monotonic_time(:millisecond) - start
    invoke_callback(config.on_error, [attempt, elapsed, reason])
    apply_fallback(config.fallback, reason, elapsed)
  end

  # Retry with the caller's original opts — rebuilding from config would drop
  # every provider opt (:model, :tools, :max_tokens, callbacks), silently
  # downgrading retried calls to the provider's default model with no tools.
  defp attempt_retry(true, reason, provider, messages, config, opts, attempt, elapsed) do
    wait = config.retry_base_ms * (attempt + 1)
    invoke_callback(config.on_retry, [attempt, elapsed, wait, reason])
    Process.sleep(wait)
    chat_attempt(provider, messages, opts, attempt + 1)
  end

  defp attempt_retry(false, reason, _provider, _messages, config, _opts, attempt, elapsed) do
    invoke_callback(config.on_error, [attempt, elapsed, reason])
    apply_fallback(config.fallback, reason, elapsed)
  end

  defp invoke_callback(nil, _args), do: :ok
  defp invoke_callback(fun, args), do: apply(fun, args)

  defp apply_fallback(nil, reason, _elapsed), do: {:error, reason}

  defp apply_fallback(fun, _reason, elapsed) when is_function(fun, 0),
    do: {:ok, fun.(), %{input_tokens: 0, output_tokens: 0, duration_ms: elapsed}}

  defp call_provider(provider, messages, opts) do
    provider
    |> function_exported?(:chat_with_usage, 2)
    |> call_with_arity(provider, messages, opts)
  end

  defp call_with_arity(true, provider, messages, opts),
    do: provider.chat_with_usage(messages, opts)

  defp call_with_arity(false, provider, messages, opts) do
    provider.chat(messages, opts)
    |> with_zero_usage()
  end

  defp with_zero_usage({:ok, ai}), do: {:ok, ai, %{input_tokens: 0, output_tokens: 0}}
  defp with_zero_usage({:error, _} = err), do: err

  @doc """
  Default retryable error classifier.

  Returns `true` for:
  - HTTP 429 (rate limit)
  - `Req.TransportError` (connection issues)
  - HTTP 5xx (server errors)
  """
  @spec default_retryable?(term()) :: boolean()
  def default_retryable?({429, _}), do: true
  def default_retryable?(%{__struct__: Req.TransportError}), do: true
  def default_retryable?({status, _}) when is_integer(status) and status >= 500, do: true
  def default_retryable?(_), do: false

  @doc """
  Format an LLM error reason into a human-readable string.
  """
  @spec format_error(term()) :: String.t()
  def format_error({status, %{"error" => %{"message" => msg}}}) when is_binary(msg) do
    "HTTP #{status}: #{msg |> String.split("\n") |> hd() |> String.slice(0, 120)}"
  end

  def format_error({status, body}) when is_integer(status) do
    "HTTP #{status}: #{body |> inspect() |> String.slice(0, 200)}"
  end

  def format_error(other), do: inspect(other)
end
