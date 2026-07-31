defmodule LangEx.Middleware.ToolRetry do
  @moduledoc """
  Middleware that retries a tool call that failed before the model sees it.

  A tool that reads from an API, a database, or a cluster fails transiently.
  Handing that failure to the model wastes a turn at best, and at worst
  teaches it the tool is broken and to stop using it. Retrying inside the
  call keeps the failure invisible when it was momentary and reports it once
  when it was not.

  A failure is a tool result marked `status: :error` — what
  `LangEx.Tool.Node` produces when a tool raises — or a raised exception when
  the agent is configured to let errors propagate. The last failure is what
  the model sees, so a genuinely broken tool still reports itself.

  Retries happen inside the tool call, so they count against the tool
  timeout: budget `:max_attempts` and `:backoff` to fit within the
  `:timeout` configured for the tools step.

  ## Options

  - `:max_attempts` — total attempts per call, including the first.
    Default `2`.
  - `:backoff` — milliseconds to wait before each retry: a non-negative
    integer, or `(attempt -> milliseconds)` for growing delays. Default `0`.
  - `:tools` — names of the tools to retry, or `:all` for every tool.
    Default `:all`.

  ## Example

      ToolRetry.new(
        max_attempts: 3,
        backoff: fn attempt -> attempt * 250 end,
        tools: ["query_metrics", "fetch_logs"]
      )
  """

  require Logger

  alias LangEx.Message
  alias LangEx.Middleware

  @default_attempts 2

  @doc "Builds a tool-retry middleware. See the module doc for options."
  @spec new(keyword()) :: Middleware.t()
  def new(opts \\ []) do
    Middleware.new(name: :tool_retry, wrap_tool_call: wrapper(opts))
  end

  defp wrapper(opts) do
    settings = %{
      attempts: Keyword.get(opts, :max_attempts, @default_attempts),
      backoff: Keyword.get(opts, :backoff, 0),
      tools: Keyword.get(opts, :tools, :all)
    }

    fn request, execute -> dispatch(request, execute, settings) end
  end

  defp dispatch(request, execute, settings) do
    request.tool_call.name
    |> covered?(settings.tools)
    |> attempt_all(request, execute, settings)
  end

  defp covered?(_name, :all), do: true
  defp covered?(name, names) when is_list(names), do: name in names

  defp attempt_all(false, request, execute, _settings), do: execute.(request)

  defp attempt_all(true, request, execute, settings) do
    1..settings.attempts
    |> Enum.reduce_while(nil, fn n, _previous -> try_once(n, request, execute, settings) end)
    |> unwrap()
  end

  defp try_once(attempt, request, execute, settings) do
    attempt
    |> pause(settings.backoff)
    |> then(fn :ok -> run(request, execute) end)
    |> classify(attempt, request, settings)
  end

  defp pause(1, _backoff), do: :ok
  defp pause(attempt, backoff) when is_integer(backoff), do: sleep(backoff, attempt)

  defp pause(attempt, backoff) when is_function(backoff, 1),
    do: attempt |> backoff.() |> sleep(attempt)

  defp sleep(0, _attempt), do: :ok
  defp sleep(milliseconds, _attempt) when milliseconds > 0, do: Process.sleep(milliseconds)

  defp run(request, execute) do
    {:ok, execute.(request)}
  rescue
    exception -> {:raised, exception, __STACKTRACE__}
  end

  defp classify(outcome, attempt, request, %{attempts: attempts}) when attempt >= attempts,
    do: {:halt, exhausted(outcome, attempt, request)}

  defp classify(outcome, attempt, request, _settings) do
    outcome
    |> failed?()
    |> continue(outcome, attempt, request)
  end

  defp failed?({:raised, _exception, _stacktrace}), do: true
  defp failed?({:ok, result}), do: Message.tool_error?(result)

  defp continue(false, outcome, _attempt, _request), do: {:halt, outcome}

  defp continue(true, outcome, attempt, request) do
    Logger.warning(
      "ToolRetry: #{request.tool_call.name} failed on attempt #{attempt} " <>
        "(#{describe(outcome)}) — retrying"
    )

    {:cont, outcome}
  end

  defp exhausted(outcome, 1, _request), do: outcome

  defp exhausted(outcome, attempt, request) do
    outcome
    |> failed?()
    |> log_exhausted(outcome, attempt, request)
  end

  defp log_exhausted(false, outcome, _attempt, _request), do: outcome

  defp log_exhausted(true, outcome, attempt, request) do
    Logger.warning(
      "ToolRetry: #{request.tool_call.name} still failing after #{attempt} attempts " <>
        "(#{describe(outcome)}) — reporting to the model"
    )

    outcome
  end

  defp describe({:raised, exception, _stacktrace}), do: Exception.message(exception)
  defp describe({:ok, result}), do: result.content

  defp unwrap({:ok, result}), do: result
  defp unwrap({:raised, exception, stacktrace}), do: reraise(exception, stacktrace)
end
