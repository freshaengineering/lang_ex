defmodule LangEx.LLM.Gemini.SSE do
  @moduledoc false

  alias LangEx.Message

  @type callbacks :: %{on_token: (String.t() -> any()) | nil}
  @type state :: %{
          text: String.t(),
          tools: %{optional(non_neg_integer()) => map()},
          tool_index: non_neg_integer(),
          usage: map(),
          line_buffer: String.t()
        }

  @spec initial_state() :: state()
  def initial_state do
    %{text: "", tools: %{}, tool_index: 0, usage: %{}, line_buffer: ""}
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

  defp apply_payload(json_str, acc, callbacks) do
    json_str
    |> Jason.decode()
    |> apply_event(acc, callbacks)
  end

  defp apply_event({:ok, event}, acc, callbacks) do
    updated = handle_event(event, acc)
    emit_tokens(event, callbacks.on_token)
    updated
  end

  defp apply_event(_, acc, _callbacks), do: acc

  defp emit_tokens(event, on_token) do
    event
    |> parts()
    |> Enum.each(&emit_part_token(&1, on_token))
  end

  defp emit_part_token(%{"thought" => true}, _), do: :ok

  defp emit_part_token(%{"text" => text}, on_token)
       when is_binary(text) and text != "" and is_function(on_token, 1),
       do: on_token.(text)

  defp emit_part_token(_, _), do: :ok

  defp handle_event(event, state) do
    event
    |> parts()
    |> Enum.reduce(state, &apply_part/2)
    |> put_usage(event)
  end

  defp parts(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]}) when is_list(parts),
    do: parts

  defp parts(_), do: []

  defp apply_part(%{"thought" => true}, state), do: state

  defp apply_part(%{"text" => text}, state) when is_binary(text),
    do: %{state | text: state.text <> text}

  defp apply_part(%{"functionCall" => call}, state) when is_map(call),
    do: apply_function_call(call, state)

  defp apply_part(_, state), do: state

  defp apply_function_call(%{"id" => id} = call, state) when is_binary(id) do
    state.tools
    |> Enum.find(&match?({_idx, %{id: ^id}}, &1))
    |> merge_found(call, state)
  end

  defp apply_function_call(call, state), do: apply_named_call(call, state)

  defp merge_found({idx, _tool}, call, state),
    do: update_in(state, [:tools, idx], &merge_tool(&1, call))

  defp merge_found(nil, call, state), do: apply_named_call(call, state)

  defp apply_named_call(%{"name" => name} = call, %{tool_index: idx} = state)
       when is_binary(name) do
    state.tools
    |> Map.get(idx - 1)
    |> merge_named(name, call, state)
  end

  defp apply_named_call(_call, state), do: state

  defp merge_named(
         %{name: name, id: last_id},
         name,
         %{"id" => id} = call,
         %{tool_index: idx} = state
       )
       when is_binary(last_id) and is_binary(id) and last_id != id,
       do: append_tool(state, idx, name, call)

  defp merge_named(%{name: name}, name, call, %{tool_index: idx} = state),
    do: update_in(state, [:tools, idx - 1], &merge_tool(&1, call))

  defp merge_named(_last, name, call, %{tool_index: idx} = state),
    do: append_tool(state, idx, name, call)

  defp append_tool(state, idx, name, call) do
    state
    |> put_in([:tools, idx], new_tool(name, call))
    |> Map.put(:tool_index, idx + 1)
  end

  defp new_tool(name, call) do
    %{name: name, id: call["id"], args: args_map(call)}
  end

  defp merge_tool(tool, call) do
    %{
      tool
      | id: call["id"] || tool.id,
        name: call["name"] || tool.name,
        args: Map.merge(tool.args, args_map(call))
    }
  end

  defp args_map(%{"args" => args}) when is_map(args), do: args
  defp args_map(_), do: %{}

  defp put_usage(state, %{"usageMetadata" => meta}) when is_map(meta),
    do: %{state | usage: meta}

  defp put_usage(state, _), do: state

  defp tool_calls(tools) do
    tools
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_idx, tc} ->
      %Message.ToolCall{name: tc.name, id: tc.id, args: tc.args}
    end)
  end

  defp extract_usage(%{"promptTokenCount" => inp, "candidatesTokenCount" => out}),
    do: %{input_tokens: inp, output_tokens: out}

  defp extract_usage(%{"promptTokenCount" => inp}),
    do: %{input_tokens: inp, output_tokens: 0}

  defp extract_usage(_), do: %{input_tokens: 0, output_tokens: 0}

  defp presence(""), do: nil
  defp presence(text), do: text
end
