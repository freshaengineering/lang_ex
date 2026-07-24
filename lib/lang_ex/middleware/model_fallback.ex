defmodule LangEx.Middleware.ModelFallback do
  @moduledoc """
  Middleware that retries a failed model call against fallback models.

  When the primary model call fails (provider outage, degradation, exhausted
  retries), the same request — messages and tools — is retried against an
  ordered list of fallback models, and the first success is returned. An
  incident-investigation agent is needed most exactly when infrastructure,
  possibly including its own LLM provider, is degraded.

  A failed call surfaces as a raised exception: `LangEx.LLM.ChatModel.node/1`
  crashes with a `MatchError` when the provider (or `LangEx.LLM.Resilient`
  after exhausting retries) returns `{:error, reason}`, and provider adapters
  can raise transport exceptions directly. When every fallback also fails,
  the original primary failure is re-raised with its stacktrace.

  ## Options

  - `:models` — ordered fallback list; each entry is a model string
    (provider resolved via `LangEx.LLM.Registry`) or a `{provider, model}`
    tuple pinning the provider module explicitly. Default `[]`, which makes
    the middleware a no-op.
  - `:llm_opts` — extra options merged into every fallback call
    (`:resilient`, `:thinking`, `:api_key`, ...). Default `[]`.

  ## Example

      LangEx.Middleware.ModelFallback.new(
        models: ["claude-sonnet-5", {LangEx.LLM.OpenAI, "gpt-5"}],
        llm_opts: [resilient: true]
      )
  """

  require Logger

  alias LangEx.LLM.ChatModel
  alias LangEx.Middleware

  @type model_spec :: String.t() | {module(), String.t()}

  @doc "Builds a model-fallback middleware. See the module doc for options."
  @spec new(keyword()) :: Middleware.t()
  def new(opts \\ []) do
    Middleware.new(
      name: :model_fallback,
      wrap_model_call: wrapper(Keyword.get(opts, :models, []), Keyword.get(opts, :llm_opts, []))
    )
  end

  defp wrapper([], _llm_opts), do: fn request, next -> next.(request) end

  defp wrapper(models, llm_opts),
    do: fn request, next -> attempt_primary(request, next, models, llm_opts) end

  defp attempt_primary(request, next, models, llm_opts) do
    next.(request)
  rescue
    exception -> recover(models, request, llm_opts, exception, __STACKTRACE__)
  end

  defp recover(models, request, llm_opts, exception, stacktrace) do
    Logger.warning(
      "ModelFallback: primary model call failed (#{Exception.message(exception)}), " <>
        "trying #{length(models)} fallback model(s)"
    )

    attempt_fallbacks(models, request, llm_opts, exception, stacktrace)
  end

  defp attempt_fallbacks([], _request, _llm_opts, exception, stacktrace),
    do: reraise(exception, stacktrace)

  defp attempt_fallbacks([spec | rest], request, llm_opts, exception, stacktrace) do
    call_fallback(spec, request, llm_opts)
  rescue
    failure -> next_fallback(failure, spec, rest, request, llm_opts, exception, stacktrace)
  end

  defp next_fallback(failure, spec, rest, request, llm_opts, exception, stacktrace) do
    Logger.warning(
      "ModelFallback: fallback model #{model_name(spec)} failed " <>
        "(#{Exception.message(failure)})"
    )

    attempt_fallbacks(rest, request, llm_opts, exception, stacktrace)
  end

  # Mirrors LangEx.Prebuilt.model_fn/1: a ChatModel node built with the
  # request's tools, called with the request's messages and usage over state.
  defp call_fallback(spec, request, llm_opts) do
    spec
    |> fallback_opts(request.tools, llm_opts)
    |> ChatModel.node()
    |> then(& &1.(fallback_state(request)))
  end

  defp fallback_opts({provider, model}, tools, llm_opts),
    do: [provider: provider, model: model] ++ Keyword.put(llm_opts, :tools, tools)

  defp fallback_opts(model, tools, llm_opts) when is_binary(model),
    do: [model: model] ++ Keyword.put(llm_opts, :tools, tools)

  defp fallback_state(%{messages: messages, state: state}) do
    Map.merge(state, %{messages: messages, llm_usage: Map.get(state, :llm_usage, %{})})
  end

  defp model_name({_provider, model}), do: model
  defp model_name(model), do: model
end
