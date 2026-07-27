defmodule LangEx.Config do
  @moduledoc """
  Layered configuration resolution for LangEx.

  Resolution order (first non-nil wins):
  1. Explicit opts passed to function calls
  2. Application environment (`config :lang_ex, :openai, api_key: "..."`)
  3. System environment variables (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`)

  Custom providers can be registered via application config:

      config :lang_ex, :providers,
        groq: %{env_key: "GROQ_API_KEY", default_model: "llama-3.3-70b"}
  """

  @builtin_defaults %{
    openai: %{env_key: "OPENAI_API_KEY", default_model: "gpt-4o"},
    anthropic: %{env_key: "ANTHROPIC_API_KEY", default_model: "claude-sonnet-5"},
    gemini: %{env_key: "GEMINI_API_KEY", default_model: "gemini-2.5-flash"}
  }

  @doc "Resolves the API key for a given provider."
  @spec api_key(atom(), keyword()) :: String.t() | nil
  def api_key(provider, opts \\ []) do
    opts[:api_key] || app_config(provider, :api_key) ||
      System.get_env(provider_defaults(provider).env_key)
  end

  @doc "Resolves the API key, raising if not found."
  @spec api_key!(atom(), keyword()) :: String.t()
  def api_key!(provider, opts \\ []) do
    provider |> api_key(opts) |> require_key!(provider)
  end

  defp require_key!(nil, provider), do: raise("no API key configured for #{provider}")
  defp require_key!(key, _provider), do: key

  @doc "Resolves the model name for a provider."
  @spec model(atom(), keyword()) :: String.t()
  def model(provider, opts \\ []) do
    opts[:model] || app_config(provider, :model) || provider_defaults(provider).default_model
  end

  @doc "Returns the provider defaults map, merging built-in with user-configured."
  @spec provider_defaults(atom()) :: %{env_key: String.t(), default_model: String.t()}
  def provider_defaults(provider) do
    @builtin_defaults
    |> Map.fetch(provider)
    |> fetch_defaults(provider)
  end

  defp fetch_defaults({:ok, defaults}, _provider), do: defaults

  defp fetch_defaults(:error, provider),
    do: :lang_ex |> Application.get_env(:providers, %{}) |> Map.fetch!(provider)

  defp app_config(section, key) do
    :lang_ex
    |> Application.get_env(section, [])
    |> Keyword.get(key)
  end
end
