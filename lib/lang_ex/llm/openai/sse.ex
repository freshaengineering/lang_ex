defmodule LangEx.LLM.OpenAI.SSE do
  @moduledoc false

  alias LangEx.Message

  @type callbacks :: %{on_token: (String.t() -> any()) | nil}
  @type state :: %{
          text: String.t(),
          tools: %{optional(non_neg_integer()) => map()},
          usage: map(),
          line_buffer: String.t()
        }

  @spec initial_state() :: state()
  def initial_state do
    %{text: "", tools: %{}, usage: %{}, line_buffer: ""}
  end

  @spec callbacks((String.t() -> any()) | nil) :: callbacks()
  def callbacks(on_token), do: %{on_token: on_token}

  @spec process_chunk(state(), callbacks(), String.t()) :: state()
  def process_chunk(state, callbacks, chunk) do
    {lines, remainder} =
      (state.line_buffer <> chunk)
      |> split_buffer()

    Enum.reduce(lines, %{state | line_buffer: remainder}, &reduce_line(&1, &2, callbacks))
  end

  @spec parse_response(String.t(), callbacks()) :: {:ok, Message.AI.t(), map()}
  def parse_response(raw, callbacks) do
    raw
    |> String.split("\n")
    |> Enum.reduce(initial_state(), &reduce_line(&1, &2, callbacks))
    |> build_message()
  end

  @spec build_message(state()) :: {:ok, Message.AI.t(), map()}
  def build_message(state) do
    {:ok, Message.ai(presence(state.text), tool_calls: tool_calls(state.tools)),
     extract_usage(state.usage)}
  end

  defp split_buffer(buffer) do
    buffer
    |> String.split("\n")
    |> split_lines()
  end

  defp split_lines([single]), do: {[], single}
  defp split_lines(parts), do: {Enum.slice(parts, 0..-2//1), List.last(parts)}

  defp reduce_line("data: " <> payload, acc, callbacks) do
    payload
    |> String.trim()
    |> apply_payload(acc, callbacks)
  end

  defp reduce_line(_line, acc, _callbacks), do: acc

  defp apply_payload("[DONE]", acc, _callbacks), do: acc

  defp apply_payload(json_str, acc, callbacks) do
    json_str
    |> Jason.decode()
    |> apply_event(acc, callbacks)
  end

  defp apply_event({:ok, event}, acc, callbacks) do
    updated = handle_event(event, acc)
    emit_token(event, callbacks.on_token)
    updated
  end

  defp apply_event(_, acc, _callbacks), do: acc

  defp emit_token(%{"choices" => [%{"delta" => %{"content" => text}} | _]}, on_token)
       when is_binary(text) and text != "" and is_function(on_token, 1),
       do: on_token.(text)

  defp emit_token(_, _), do: :ok

  defp handle_event(%{"choices" => [%{"delta" => delta} | _]} = event, state) do
    state
    |> append_text(delta)
    |> merge_tool_calls(delta)
    |> put_usage(event)
  end

  defp handle_event(event, state), do: put_usage(state, event)

  defp append_text(state, %{"content" => text}) when is_binary(text),
    do: %{state | text: state.text <> text}

  defp append_text(state, _), do: state

  defp merge_tool_calls(state, %{"tool_calls" => calls}) when is_list(calls),
    do: Enum.reduce(calls, state, &merge_tool_call/2)

  defp merge_tool_calls(state, _), do: state

  defp merge_tool_call(%{"index" => idx} = call, state),
    do: update_in(state, [:tools, idx], &merge_tool(&1, call))

  defp merge_tool_call(_, state), do: state

  defp merge_tool(nil, call) do
    %{id: call["id"], name: function_field(call, "name"), args: args_fragment(call)}
  end

  defp merge_tool(existing, call) do
    %{
      id: call["id"] || existing.id,
      name: function_field(call, "name") || existing.name,
      args: existing.args <> args_fragment(call)
    }
  end

  defp function_field(%{"function" => function}, key) when is_map(function), do: function[key]
  defp function_field(_, _), do: nil

  defp args_fragment(call) do
    call
    |> function_field("arguments")
    |> binary_or_empty()
  end

  defp binary_or_empty(args) when is_binary(args), do: args
  defp binary_or_empty(_), do: ""

  defp put_usage(state, %{"usage" => usage}) when is_map(usage), do: %{state | usage: usage}
  defp put_usage(state, _), do: state

  defp tool_calls(tools) do
    tools
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_idx, tc} ->
      %Message.ToolCall{name: tc.name, id: tc.id, args: decode_args(tc.args)}
    end)
  end

  defp decode_args(args) when is_binary(args) do
    args
    |> Jason.decode()
    |> parsed_args()
  end

  defp decode_args(args) when is_map(args), do: args
  defp decode_args(_), do: %{}

  defp parsed_args({:ok, parsed}), do: parsed
  defp parsed_args(_), do: %{}

  defp extract_usage(%{"prompt_tokens" => inp, "completion_tokens" => out}),
    do: %{input_tokens: inp, output_tokens: out}

  defp extract_usage(_), do: %{input_tokens: 0, output_tokens: 0}

  defp presence(""), do: nil
  defp presence(text), do: text
end
