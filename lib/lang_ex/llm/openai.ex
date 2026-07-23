defmodule LangEx.LLM.OpenAI do
  @moduledoc """
  OpenAI chat completions adapter with tool/function calling support.

  Supports GPT-4o and other OpenAI models (and OpenAI-compatible APIs like
  OpenRouter) via the `/v1/chat/completions` endpoint.

  ## Tool Calling

  Pass `:tools` (list of `%LangEx.Tool{}`) to enable tool calling.
  The adapter returns `{:ok, %Message.AI{tool_calls: [...]}}` when the
  model requests tool calls. Use `LangEx.Tool.Node` to execute them.

      LangEx.LLM.OpenAI.chat(messages,
        model: "gpt-4o-mini",
        tools: [%LangEx.Tool{name: "get_weather", ...}]
      )
  """

  @behaviour LangEx.LLM

  alias LangEx.Config
  alias LangEx.Message
  alias LangEx.Tool

  @base_url "https://api.openai.com/v1"

  @impl true
  def chat(messages, opts \\ []) do
    messages
    |> chat_with_usage(opts)
    |> drop_usage()
  end

  defp drop_usage({:ok, ai, _usage}), do: {:ok, ai}
  defp drop_usage({:error, _} = err), do: err

  @impl true
  def chat_with_usage(messages, opts \\ []) do
    api_key = Config.api_key!(:openai, opts)
    model = Config.model(:openai, opts)
    tools = Keyword.get(opts, :tools, [])
    base_url = Keyword.get(opts, :base_url, @base_url)

    %{model: model, messages: Enum.map(messages, &format_message/1)}
    |> put_present(:temperature, opts[:temperature])
    |> put_present(:max_tokens, opts[:max_tokens])
    |> put_tools(tools)
    |> put_tool_choice(Keyword.get(opts, :tool_choice))
    |> send_request(api_key, base_url)
    |> handle_response()
  end

  defp put_tool_choice(body, nil), do: body
  defp put_tool_choice(body, choice), do: Map.put(body, :tool_choice, format_tool_choice(choice))

  defp format_tool_choice(:auto), do: "auto"
  defp format_tool_choice(choice) when choice in [:required, :any], do: "required"

  defp format_tool_choice({:tool, name}),
    do: %{type: "function", function: %{name: to_string(name)}}

  defp handle_response({:ok, %{status: 200, body: response}}) do
    usage = extract_openai_usage(response)

    response
    |> extract_choice()
    |> handle_choice(response, usage)
  end

  defp handle_response({:ok, %{status: status, body: resp_body}}),
    do: {:error, {status, resp_body}}

  defp handle_response({:error, reason}),
    do: {:error, reason}

  defp handle_choice({:text, content}, _, usage),
    do: {:ok, Message.ai(content), usage}

  defp handle_choice({:tool_calls, raw_calls}, _, usage) do
    {:ok, Message.ai(nil, tool_calls: Enum.map(raw_calls, &parse_tool_call/1)), usage}
  end

  defp handle_choice(:error, response, _usage),
    do: {:error, {:unexpected_response, response}}

  defp extract_openai_usage(%{"usage" => %{"prompt_tokens" => inp, "completion_tokens" => out}}) do
    %{input_tokens: inp, output_tokens: out}
  end

  defp extract_openai_usage(_), do: %{input_tokens: 0, output_tokens: 0}

  defp extract_choice(%{"choices" => [%{"message" => message} | _]}),
    do: classify_message(message["tool_calls"], message["content"])

  defp extract_choice(_), do: :error

  defp classify_message(calls, _) when is_list(calls) and calls != [],
    do: {:tool_calls, calls}

  defp classify_message(_, content) when is_binary(content),
    do: {:text, content}

  defp classify_message(_, _), do: :error

  defp parse_tool_call(%{"id" => id, "function" => %{"name" => name, "arguments" => raw_args}}) do
    %Message.ToolCall{name: name, id: id, args: decode_args(raw_args)}
  end

  defp decode_args(args) when is_binary(args), do: args |> Jason.decode() |> parse_decoded()
  defp decode_args(args) when is_map(args), do: args
  defp decode_args(_), do: %{}

  defp parse_decoded({:ok, parsed}), do: parsed
  defp parse_decoded(_), do: %{}

  defp send_request(body, api_key, base_url) do
    Req.post("#{base_url}/chat/completions",
      json: body,
      headers: [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ]
    )
  end

  defp format_message(%Message.Human{content: c}), do: %{role: "user", content: c}

  defp format_message(%Message.AI{content: c, tool_calls: []}),
    do: %{role: "assistant", content: c}

  defp format_message(%Message.AI{content: c, tool_calls: calls}) when calls != [],
    do: %{role: "assistant", content: c, tool_calls: Enum.map(calls, &format_outgoing_call/1)}

  defp format_message(%Message.System{content: c}), do: %{role: "system", content: c}

  defp format_message(%Message.Tool{content: c, tool_call_id: id}),
    do: %{role: "tool", content: c, tool_call_id: id}

  defp format_message(%{role: _} = raw), do: raw

  defp format_message(%{content: c, tool_calls: calls}) when is_list(calls) and calls != [],
    do: %{role: "assistant", content: c, tool_calls: Enum.map(calls, &format_outgoing_call/1)}

  defp format_message(%{content: c, tool_calls: _}), do: %{role: "assistant", content: c}

  defp format_message(%{content: c, tool_call_id: id}),
    do: %{role: "tool", content: c, tool_call_id: id}

  defp format_message(%{content: c}), do: %{role: "user", content: c}

  defp format_outgoing_call(%Message.ToolCall{name: n, id: id, args: a}),
    do: %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => n, "arguments" => Jason.encode!(a)}
    }

  defp format_outgoing_call(%{name: n, id: id, args: a}),
    do: %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => to_string(n), "arguments" => encode_args(a)}
    }

  defp format_outgoing_call(raw), do: raw

  defp encode_args(a) when is_binary(a), do: a
  defp encode_args(a), do: Jason.encode!(a)

  defp put_tools(body, []), do: body

  defp put_tools(body, tools) do
    tools
    |> Enum.map(&format_tool/1)
    |> then(&Map.put(body, :tools, &1))
  end

  defp format_tool(%Tool{name: n, description: d, parameters: p}),
    do: %{type: "function", function: %{name: n, description: d, parameters: p}}

  defp format_tool(raw), do: raw

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
