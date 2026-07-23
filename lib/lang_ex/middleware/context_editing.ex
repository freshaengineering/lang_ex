defmodule LangEx.Middleware.ContextEditing do
  @moduledoc """
  Middleware that clears the *contents* of stale tool results.

  Distinct from summarisation: instead of dropping or condensing rounds, it
  keeps the full message skeleton (every tool call and reply stays in place)
  but blanks the body of large, older `%Message.Tool{}` results — the
  outputs the model has already reasoned over and no longer needs verbatim.
  The rewrite persists via `LangEx.Message.remove_all/0`, and is idempotent:
  once a result is replaced by the short placeholder it falls under the
  threshold and is left alone.

  No LLM call — cheap, deterministic context recovery. Composes with
  `LangEx.Middleware.Summarization`; typically you reach for one or the
  other.

  ## Options

  - `:keep_last` - most recent tool results left untouched (default `3`)
  - `:clear_at_chars` - only results larger than this are cleared
    (default `4_000`)
  - `:placeholder` - replacement content for cleared results
  """

  alias LangEx.Message
  alias LangEx.Middleware

  @default_keep_last 3
  @default_clear_at 4_000
  @default_placeholder "[cleared: earlier tool output elided to save context]"

  @doc "Builds a context-editing middleware. See the module doc for options."
  @spec new(keyword()) :: Middleware.t()
  def new(opts \\ []) do
    Middleware.new(name: :context_editing, before_model: hook(opts))
  end

  defp hook(opts) do
    keep_last = Keyword.get(opts, :keep_last, @default_keep_last)
    clear_at = Keyword.get(opts, :clear_at_chars, @default_clear_at)
    placeholder = Keyword.get(opts, :placeholder, @default_placeholder)

    fn state ->
      state.messages
      |> edit(keep_last, clear_at, placeholder)
      |> persist(state.messages)
    end
  end

  defp edit(messages, keep_last, clear_at, placeholder) do
    clearable = clearable_positions(messages, keep_last)

    messages
    |> Enum.with_index()
    |> Enum.map(fn {msg, index} ->
      clear(msg, MapSet.member?(clearable, index), clear_at, placeholder)
    end)
  end

  defp clearable_positions(messages, keep_last) do
    for({%Message.Tool{}, index} <- Enum.with_index(messages), do: index)
    |> Enum.drop(-keep_last)
    |> MapSet.new()
  end

  defp clear(%Message.Tool{content: c} = msg, true, clear_at, placeholder)
       when is_binary(c) and byte_size(c) > clear_at,
       do: %{msg | content: placeholder}

  defp clear(msg, _clearable, _clear_at, _placeholder), do: msg

  defp persist(edited, original) when edited == original, do: %{}
  defp persist(edited, _original), do: %{messages: [Message.remove_all() | edited]}
end
