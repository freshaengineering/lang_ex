defmodule LangEx.LLM.Anthropic.Formatter do
  @moduledoc false

  alias LangEx.Message

  def format_message(%Message.Human{content: c}), do: %{role: "user", content: c}

  def format_message(%Message.AI{content: c, tool_calls: []}),
    do: %{role: "assistant", content: c}

  def format_message(%Message.AI{content: c, tool_calls: calls}) when calls != [],
    do: %{
      role: "assistant",
      content: text_blocks(c) ++ Enum.map(calls, &format_outgoing_call/1)
    }

  def format_message(%Message.Tool{content: c, tool_call_id: id} = tool),
    do: %{
      role: "user",
      content: [
        %{"type" => "tool_result", "tool_use_id" => id, "content" => c}
        |> flag_error(tool)
      ]
    }

  def format_message(%{role: _, content: _} = raw), do: raw
  def format_message(%{role: _} = raw), do: raw

  def format_message(%{content: c, tool_calls: calls}) when is_list(calls) and calls != [],
    do: %{
      role: "assistant",
      content: text_blocks(c) ++ Enum.map(calls, &format_outgoing_call/1)
    }

  def format_message(%{content: c, tool_calls: _}), do: %{role: "assistant", content: c}

  def format_message(%{content: c, tool_call_id: id}),
    do: %{
      role: "user",
      content: [%{"type" => "tool_result", "tool_use_id" => id, "content" => c}]
    }

  def format_message(%{content: c}), do: %{role: "user", content: c}

  def extract_system(messages) do
    {system_msgs, rest} = Enum.split_with(messages, &match?(%Message.System{}, &1))
    {join_system(system_msgs), rest}
  end

  defp join_system([]), do: nil
  defp join_system(msgs), do: Enum.map_join(msgs, "\n", & &1.content)

  # Anthropic models tool failure natively; telling it the call failed reads
  # better than leaving the model to infer it from the error prose.
  defp flag_error(block, %Message.Tool{status: :error}), do: Map.put(block, "is_error", true)
  defp flag_error(block, _tool), do: block

  defp format_outgoing_call(%Message.ToolCall{name: n, id: id, args: a}),
    do: %{"type" => "tool_use", "id" => id, "name" => n, "input" => a}

  defp format_outgoing_call(%{name: n, id: id, args: a}),
    do: %{"type" => "tool_use", "id" => id, "name" => to_string(n), "input" => a}

  defp format_outgoing_call(raw), do: raw

  defp text_blocks(nil), do: []
  defp text_blocks(""), do: []
  defp text_blocks(text), do: [%{"type" => "text", "text" => text}]
end
