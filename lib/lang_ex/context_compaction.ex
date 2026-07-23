defmodule LangEx.ContextCompaction do
  @moduledoc """
  Manages context window size by compacting older tool-call rounds.

  When the message history exceeds a byte budget, the oldest rounds
  (AI tool-call + tool results) are dropped and replaced with a brief
  summary of what tools were called and their outcomes. This preserves
  the investigation narrative while staying within the LLM's effective
  context window.

  ## Usage

      messages = LangEx.ContextCompaction.compact_if_needed(messages)

      # With custom budget:
      messages = LangEx.ContextCompaction.compact_if_needed(messages, max_bytes: 100_000)

  ## Options

  - `:max_bytes` — byte budget for the message list (default `200_000`)
  - `:min_rounds_to_keep` — never drop below this many rounds (default `2`)
  - `:error_detector` — `fn(content :: String.t()) -> boolean()` to detect
    error payloads in tool results (default: JSON `"error"`/`"errors"` key detection)
  - `:summarizer` — `fn(dropped_messages :: [Message.t()]) -> String.t()` to
    produce a real summary of the dropped rounds' content (e.g. an LLM call).
    When absent, a mechanical notice listing tool names and outcomes is used.
  - `:compaction_notice` — `fn(summary_text, dropped_count) -> Message.t()`
    to customize the compaction notice message
  """

  alias LangEx.Message

  require Logger

  @default_max_bytes 200_000
  @default_min_rounds 2
  @empty_result_threshold 200

  @doc """
  Compact messages if total size exceeds the context budget.

  Returns messages unchanged if under budget, or with oldest rounds
  replaced by a summary notice if over budget.
  """
  @spec compact_if_needed([Message.t()], keyword()) :: [Message.t()]
  def compact_if_needed(messages, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    enforce_budget(messages, messages_byte_size(messages), max_bytes, opts)
  end

  defp enforce_budget(messages, current_bytes, max_bytes, _opts) when current_bytes <= max_bytes,
    do: messages

  defp enforce_budget(messages, _current_bytes, _max_bytes, opts),
    do: compact(messages, opts)

  @doc "Calculate total byte size of a message list."
  @spec messages_byte_size([Message.t()]) :: non_neg_integer()
  def messages_byte_size(messages) when is_list(messages) do
    messages |> Enum.map(&message_byte_size/1) |> Enum.sum()
  end

  defp compact([system | rest], opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    min_rounds = Keyword.get(opts, :min_rounds_to_keep, @default_min_rounds)
    error_detector = Keyword.get(opts, :error_detector, &default_error_detector/1)
    notice_builder = Keyword.get(opts, :compaction_notice, &default_compaction_notice/2)
    summarizer = Keyword.get(opts, :summarizer)

    {rounds, trailing} = chunk_into_rounds(rest)
    total = messages_byte_size([system | rest])
    dropped_count = count_rounds_to_drop(rounds, total, max_bytes, min_rounds)

    apply_compaction(dropped_count, system, rest, rounds, trailing, %{
      error_detector: error_detector,
      notice_builder: notice_builder,
      summarizer: summarizer
    })
  end

  defp apply_compaction(0, system, rest, _rounds, _trailing, _opts), do: [system | rest]

  defp apply_compaction(dropped_count, system, _rest, rounds, trailing, opts) do
    {dropped, kept} = Enum.split(rounds, dropped_count)
    kept_flat = List.flatten(kept) ++ trailing

    Logger.info(
      "ContextCompact: dropped #{dropped_count}/#{length(rounds)} rounds " <>
        "(#{messages_byte_size([system | kept_flat])} bytes after)"
    )

    notice =
      dropped
      |> summary_text(opts.error_detector, opts.summarizer)
      |> then(&opts.notice_builder.(&1, dropped_count))

    [system, notice | kept_flat]
  end

  defp summary_text(dropped, error_detector, nil),
    do: format_dropped_summaries(dropped, error_detector)

  defp summary_text(dropped, _error_detector, summarizer) when is_function(summarizer, 1) do
    dropped
    |> List.flatten()
    |> summarizer.()
    |> wrap_summary()
  end

  defp wrap_summary(text), do: "Summary of dropped rounds:\n#{text}\n\n"

  defp default_compaction_notice(summary_text, count) do
    Message.human(
      "[Context compacted — #{count} earlier round(s) removed.]\n\n" <>
        summary_text <>
        "Do NOT re-query these tools with the same arguments. " <>
        "Rely on your prior findings for context."
    )
  end

  defp chunk_into_rounds(messages) do
    {rounds, current, trailing} =
      Enum.reduce(messages, {[], [], []}, &chunk_message/2)

    {finalize_rounds(rounds, current), trailing}
  end

  defp chunk_message(
         %Message.AI{tool_calls: calls} = msg,
         {rounds, current, _trailing}
       )
       when is_list(calls) and calls != [] do
    {flush_current(rounds, current), [msg], []}
  end

  defp chunk_message(%Message.Tool{} = msg, {rounds, [_ | _] = current, _trailing}),
    do: {rounds, [msg | current], []}

  defp chunk_message(msg, {rounds, [], trailing}),
    do: {rounds, [], trailing ++ [msg]}

  defp chunk_message(msg, {rounds, current, _trailing}),
    do: {rounds ++ [Enum.reverse(current)], [], [msg]}

  defp flush_current(rounds, []), do: rounds
  defp flush_current(rounds, current), do: rounds ++ [Enum.reverse(current)]

  defp finalize_rounds(rounds, []), do: rounds
  defp finalize_rounds(rounds, current), do: rounds ++ [Enum.reverse(current)]

  defp count_rounds_to_drop(_rounds, total, max_bytes, _min_rounds)
       when total <= max_bytes,
       do: 0

  defp count_rounds_to_drop(rounds, _, _, min_rounds)
       when length(rounds) <= min_rounds,
       do: 0

  defp count_rounds_to_drop([oldest | rest], total, max_bytes, min_rounds) do
    1 + count_rounds_to_drop(rest, total - messages_byte_size(oldest), max_bytes, min_rounds)
  end

  defp format_dropped_summaries([], _error_detector), do: ""

  defp format_dropped_summaries(rounds, error_detector) do
    rounds
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {round_msgs, idx} ->
      {tool_names, outcome} = summarize_round(round_msgs, error_detector)
      "- Round #{idx}: called #{tool_names} -> #{outcome}"
    end)
    |> then(&"Summary of dropped rounds:\n#{&1}\n\n")
  end

  defp summarize_round(round_msgs, error_detector) do
    tool_names =
      round_msgs
      |> Enum.flat_map(fn
        %Message.AI{tool_calls: calls} when is_list(calls) ->
          Enum.map(calls, & &1.name)

        _ ->
          []
      end)
      |> Enum.join(", ")
      |> default_on_empty("unknown")

    outcome =
      round_msgs
      |> Enum.filter(&match?(%Message.Tool{}, &1))
      |> classify_round_outcome(error_detector)

    {tool_names, outcome}
  end

  defp classify_round_outcome([], _error_detector), do: "no results"

  defp classify_round_outcome(tool_results, error_detector) do
    tool_results
    |> detect_outcome_type(error_detector)
    |> format_outcome(tool_results)
  end

  defp detect_outcome_type(tool_results, error_detector) do
    has_error =
      Enum.any?(tool_results, fn %Message.Tool{content: c} ->
        error_detector.(c || "")
      end)

    all_empty =
      Enum.all?(tool_results, fn %Message.Tool{content: c} ->
        byte_size(c || "") < @empty_result_threshold
      end)

    {has_error, all_empty}
  end

  defp format_outcome({true, _}, _tool_results), do: "error"
  defp format_outcome({_, true}, _tool_results), do: "empty/minimal data"

  defp format_outcome(_, tool_results) do
    tool_results
    |> Enum.map(&tool_content_size/1)
    |> Enum.sum()
    |> then(&"#{div(&1, 1000)}KB of data")
  end

  defp tool_content_size(%Message.Tool{content: c}), do: byte_size(c || "")

  defp default_on_empty("", fallback), do: fallback
  defp default_on_empty(value, _fallback), do: value

  @doc """
  Default error detector for tool results.

  Returns `true` if the content parses as JSON with an `"error"` or
  `"errors"` top-level key.
  """
  @spec default_error_detector(String.t()) :: boolean()
  def default_error_detector(content) when byte_size(content) == 0, do: false

  def default_error_detector(content) do
    content
    |> Jason.decode()
    |> error_payload?()
  end

  defp error_payload?({:ok, %{"error" => _}}), do: true
  defp error_payload?({:ok, %{"errors" => _}}), do: true
  defp error_payload?(_), do: false

  defp message_byte_size(%Message.Tool{content: c}) when is_binary(c), do: byte_size(c)
  defp message_byte_size(%Message.AI{content: c}) when is_binary(c), do: byte_size(c)
  defp message_byte_size(%Message.Human{content: c}) when is_binary(c), do: byte_size(c)
  defp message_byte_size(%Message.System{content: c}) when is_binary(c), do: byte_size(c)
  defp message_byte_size(_), do: 0
end
