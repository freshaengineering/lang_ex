defmodule LangEx.LLM.Anthropic.SSE do
  @moduledoc false

  alias LangEx.Message

  def initial_state do
    %{text: %{}, thinking: %{}, tools: %{}, tool_json: %{}, usage: %{}, line_buffer: ""}
  end

  # Callbacks: %{on_thinking: fn accumulated -> _ | nil, on_token: fn delta -> _ | nil}
  def callbacks(on_thinking, on_token), do: %{on_thinking: on_thinking, on_token: on_token}

  def process_chunk(state, callbacks, chunk) do
    {lines, remainder} =
      (state.line_buffer <> chunk)
      |> split_buffer()

    Enum.reduce(lines, %{state | line_buffer: remainder}, &reduce_line(&1, &2, callbacks))
  end

  def parse_response(raw, callbacks) do
    raw
    |> String.split("\n")
    |> Enum.reduce(initial_state(), &reduce_line(&1, &2, callbacks))
    |> build_message()
  end

  def build_message(state) do
    text = sorted_concat(state.text)
    thinking = sorted_concat(state.thinking)

    tool_calls =
      state.tools
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {idx, tc} ->
        %Message.ToolCall{name: tc.name, id: tc.id, args: decode_tool_args(state.tool_json[idx])}
      end)

    ai = Message.ai(text, tool_calls: tool_calls)
    usage = state.usage |> extract_usage() |> Map.put(:thinking, thinking)
    {:ok, ai, usage}
  end

  defp split_buffer(buffer) do
    buffer
    |> String.split("\n")
    |> split_lines()
  end

  defp split_lines([single]), do: {[], single}
  defp split_lines(parts), do: {Enum.slice(parts, 0..-2//1), List.last(parts)}

  defp reduce_line("data: " <> json_str, acc, callbacks) do
    json_str
    |> Jason.decode()
    |> apply_event(acc, callbacks)
  end

  defp reduce_line(_line, acc, _callbacks), do: acc

  defp apply_event({:ok, event}, acc, callbacks) do
    updated = handle_event(event, acc)
    emit_thinking(event, updated, callbacks.on_thinking)
    emit_token(event, callbacks.on_token)
    updated
  end

  defp apply_event(_, acc, _callbacks), do: acc

  defp emit_thinking(
         %{"type" => "content_block_delta", "delta" => %{"type" => "thinking_delta"}},
         state,
         on_thinking
       )
       when is_function(on_thinking, 1) do
    state.thinking |> sorted_concat() |> then(on_thinking)
  end

  defp emit_thinking(_, _, _), do: :ok

  defp emit_token(
         %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}},
         on_token
       )
       when is_function(on_token, 1),
       do: on_token.(text)

  defp emit_token(_, _), do: :ok

  defp handle_event(
         %{"type" => "content_block_start", "index" => idx, "content_block" => block},
         state
       ),
       do: apply_block_start(block, idx, state)

  defp handle_event(
         %{"type" => "content_block_delta", "index" => idx, "delta" => delta},
         state
       ),
       do: apply_block_delta(delta, idx, state)

  defp handle_event(%{"type" => "message_delta", "usage" => usage}, state),
    do: Map.update(state, :usage, usage, &Map.merge(&1, usage))

  defp handle_event(%{"type" => "message_start", "message" => %{"usage" => usage}}, state),
    do: Map.update(state, :usage, usage, &Map.merge(&1, usage))

  defp handle_event(_event, state), do: state

  defp apply_block_start(%{"type" => "text"}, idx, state),
    do: put_in(state, [:text, idx], "")

  defp apply_block_start(%{"type" => "thinking"}, idx, state),
    do: put_in(state, [:thinking, idx], "")

  defp apply_block_start(%{"type" => "tool_use", "id" => id, "name" => name}, idx, state) do
    state
    |> put_in([:tools, idx], %{id: id, name: name})
    |> put_in([:tool_json, idx], "")
  end

  defp apply_block_start(_, _idx, state), do: state

  defp apply_block_delta(%{"type" => "text_delta", "text" => text}, idx, state),
    do: update_in(state, [:text, idx], &((&1 || "") <> text))

  defp apply_block_delta(%{"type" => "thinking_delta", "thinking" => text}, idx, state),
    do: update_in(state, [:thinking, idx], &((&1 || "") <> text))

  defp apply_block_delta(%{"type" => "input_json_delta", "partial_json" => json}, idx, state),
    do: update_in(state, [:tool_json, idx], &((&1 || "") <> json))

  defp apply_block_delta(_, _idx, state), do: state

  defp sorted_concat(indexed_map) do
    indexed_map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("", &elem(&1, 1))
  end

  defp decode_tool_args(nil), do: %{}

  defp decode_tool_args(json) do
    json
    |> Jason.decode()
    |> parse_args()
  end

  defp parse_args({:ok, parsed}), do: parsed
  defp parse_args(_), do: %{}

  defp extract_usage(usage) when is_map(usage) do
    %{
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      cache_creation_input_tokens: usage["cache_creation_input_tokens"] || 0,
      cache_read_input_tokens: usage["cache_read_input_tokens"] || 0
    }
  end

  defp extract_usage(_) do
    %{
      input_tokens: 0,
      output_tokens: 0,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0
    }
  end
end
