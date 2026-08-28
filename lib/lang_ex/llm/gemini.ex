defmodule LangEx.LLM.Gemini do
  @moduledoc """
  Google Gemini chat adapter with function calling support.

  Supports Gemini models via the `/v1beta/models/{model}:generateContent` endpoint.
  Streaming uses `:streamGenerateContent?alt=sse` and the same `x-goog-api-key`
  header.

  ## Tool Calling

  Pass `:tools` (list of `%LangEx.Tool{}`) to enable function calling.
  The adapter returns `{:ok, %Message.AI{tool_calls: [...]}}` when the
  model requests a function call. Use `LangEx.Tool.Node` to execute them.

      LangEx.LLM.Gemini.chat(messages,
        model: "gemini-2.5-flash",
        tools: [%LangEx.Tool{name: "get_weather", ...}]
      )

  ## Options

  - `:on_token` — `fn(text_delta) -> any()` callback invoked per streamed
    content token (used by graph streaming's `:messages` mode). Implies SSE
    streaming. Function-call payloads are assembled, not emitted as tokens.
  - `:stream` — use SSE streaming (`true` / `false`, default `false`). Also
    streams when `:on_token` is set. The final return stays
    `{:ok, %Message.AI{}, usage}` — streaming is how the body arrives.
  - `:tool_choice` — force function calling: `:auto` (default), `:required`/
    `:any` (must call some function), or `{:tool, name}` (must call that one)
  """

  @behaviour LangEx.LLM

  alias LangEx.Config
  alias LangEx.LLM.Gemini.SSE
  alias LangEx.Message
  alias LangEx.Tool

  @base_url "https://generativelanguage.googleapis.com/v1beta"

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
    api_key = Config.api_key!(:gemini, opts)
    model = Config.model(:gemini, opts)
    tools = Keyword.get(opts, :tools, [])
    stream? = stream_requested?(opts)

    {system_instruction, contents} = extract_system(messages)

    %{contents: Enum.map(contents, &format_content/1)}
    |> put_system_instruction(system_instruction)
    |> put_generation_config(opts)
    |> put_tools(tools)
    |> put_tool_choice(Keyword.get(opts, :tool_choice))
    |> send_request(api_key, model, SSE.callbacks(Keyword.get(opts, :on_token)), stream?)
  end

  defp stream_requested?(opts) do
    opts
    |> Keyword.get(:stream, false)
    |> stream_enabled?(Keyword.get(opts, :on_token))
  end

  defp stream_enabled?(true, _), do: true
  defp stream_enabled?(_, on_token) when is_function(on_token, 1), do: true
  defp stream_enabled?(_, _), do: false

  defp put_tool_choice(body, nil), do: body
  defp put_tool_choice(body, choice), do: Map.put(body, :tool_config, format_tool_choice(choice))

  defp format_tool_choice(:auto), do: %{function_calling_config: %{mode: "AUTO"}}

  defp format_tool_choice(choice) when choice in [:required, :any],
    do: %{function_calling_config: %{mode: "ANY"}}

  defp format_tool_choice({:tool, name}),
    do: %{function_calling_config: %{mode: "ANY", allowed_function_names: [to_string(name)]}}

  defp handle_response({:ok, %{status: 200, body: response}}) do
    usage = extract_gemini_usage(response)

    response
    |> extract_parts()
    |> handle_parts(response, usage)
  end

  defp handle_response({:ok, %{status: status, body: resp_body}}),
    do: {:error, {status, resp_body}}

  defp handle_response({:error, reason}),
    do: {:error, reason}

  defp handle_parts({:text, text}, _, usage),
    do: {:ok, Message.ai(text), usage}

  defp handle_parts({:function_call, name, args}, _, usage) do
    {:ok, Message.ai(nil, tool_calls: [%Message.ToolCall{name: name, id: nil, args: args}]),
     usage}
  end

  defp handle_parts(:error, response, _usage),
    do: {:error, {:unexpected_response, response}}

  defp extract_gemini_usage(%{"usageMetadata" => meta}) when is_map(meta) do
    %{
      input_tokens: meta["promptTokenCount"] || 0,
      output_tokens: meta["candidatesTokenCount"] || 0
    }
  end

  defp extract_gemini_usage(_), do: %{input_tokens: 0, output_tokens: 0}

  defp extract_parts(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]}) do
    find_function_call(parts) || find_text(parts) || :error
  end

  defp extract_parts(_), do: :error

  defp find_function_call(parts) do
    parts
    |> Enum.find(&Map.has_key?(&1, "functionCall"))
    |> to_function_call()
  end

  defp to_function_call(%{"functionCall" => %{"name" => name, "args" => args}}),
    do: {:function_call, name, args}

  defp to_function_call(_), do: nil

  defp find_text(parts) do
    parts
    |> Enum.find(&Map.has_key?(&1, "text"))
    |> to_text()
  end

  defp to_text(%{"text" => text}), do: {:text, text}
  defp to_text(_), do: nil

  defp send_request(body, api_key, model, callbacks, stream?) do
    [
      json: body,
      headers: [
        {"x-goog-api-key", api_key},
        {"content-type", "application/json"}
      ]
    ]
    |> add_stream_timeouts(stream?)
    |> dispatch_request(callbacks, stream?, endpoint(model, stream?))
  end

  defp endpoint(model, true),
    do: "#{@base_url}/models/#{model}:streamGenerateContent?alt=sse"

  defp endpoint(model, false),
    do: "#{@base_url}/models/#{model}:generateContent"

  defp add_stream_timeouts(opts, true),
    do: opts |> Keyword.put(:receive_timeout, 300_000) |> Keyword.put(:pool_timeout, 60_000)

  defp add_stream_timeouts(opts, false), do: opts

  defp dispatch_request(req_opts, callbacks, true, url),
    do: stream_request(req_opts, callbacks, url)

  defp dispatch_request(req_opts, _callbacks, false, url),
    do: batch_request(req_opts, url)

  defp stream_request(req_opts, callbacks, url) do
    pkey = {__MODULE__, make_ref()}
    Process.put(pkey, SSE.initial_state())

    callback = fn {:data, chunk}, {req, resp} ->
      pkey
      |> Process.get()
      |> SSE.process_chunk(callbacks, chunk)
      |> then(&Process.put(pkey, &1))

      {:cont, {req, resp}}
    end

    result =
      req_opts
      |> Keyword.put(:into, callback)
      |> then(&Req.post(url, &1))
      |> handle_streaming_response(pkey, callbacks)

    Process.delete(pkey)
    result
  end

  defp handle_streaming_response({:ok, %{status: 200, body: ""}}, pkey, _callbacks),
    do: SSE.build_message(Process.get(pkey))

  defp handle_streaming_response(
         {:ok, %{status: 200, body: %Req.Response.Async{}}},
         pkey,
         _callbacks
       ),
       do: SSE.build_message(Process.get(pkey))

  defp handle_streaming_response({:ok, %{status: 200, body: raw}}, _pkey, callbacks)
       when is_binary(raw) and byte_size(raw) > 0,
       do: SSE.parse_response(raw, callbacks)

  defp handle_streaming_response({:ok, %{status: 200, body: response}}, _pkey, _callbacks)
       when is_map(response),
       do: handle_response({:ok, %{status: 200, body: response}})

  defp handle_streaming_response({:ok, %{status: status, body: resp_body}}, _pkey, _callbacks),
    do: {:error, {status, resp_body}}

  defp handle_streaming_response({:error, reason}, _pkey, _callbacks),
    do: {:error, reason}

  defp batch_request(req_opts, url) do
    url
    |> Req.post(req_opts)
    |> handle_response()
  end

  defp extract_system(messages) do
    {system_msgs, rest} = Enum.split_with(messages, &match?(%Message.System{}, &1))
    {join_system(system_msgs), rest}
  end

  defp join_system([]), do: nil
  defp join_system(msgs), do: Enum.map_join(msgs, "\n", & &1.content)

  defp put_system_instruction(body, nil), do: body

  defp put_system_instruction(body, text),
    do: Map.put(body, :system_instruction, %{parts: [%{text: text}]})

  defp put_generation_config(body, opts) do
    %{}
    |> put_present(:temperature, opts[:temperature])
    |> put_present(:maxOutputTokens, opts[:max_tokens])
    |> merge_generation_config(body)
  end

  defp merge_generation_config(config, body) when map_size(config) == 0, do: body
  defp merge_generation_config(config, body), do: Map.put(body, :generationConfig, config)

  defp put_tools(body, []), do: body

  defp put_tools(body, tools) do
    tools
    |> Enum.map(&format_tool/1)
    |> then(&Map.put(body, :tools, [%{functionDeclarations: &1}]))
  end

  defp format_tool(%Tool{name: n, description: d, parameters: p}),
    do: %{name: n, description: d, parameters: upcase_types(p)}

  defp format_tool(raw), do: raw

  defp upcase_types(%{type: type} = schema) when is_binary(type) do
    schema
    |> Map.put(:type, String.upcase(type))
    |> upcase_properties()
    |> upcase_items()
  end

  defp upcase_types(other), do: other

  defp upcase_properties(%{properties: props} = schema) when is_map(props),
    do: Map.put(schema, :properties, Map.new(props, fn {k, v} -> {k, upcase_types(v)} end))

  defp upcase_properties(schema), do: schema

  defp upcase_items(%{items: items} = schema) when is_map(items),
    do: Map.put(schema, :items, upcase_types(items))

  defp upcase_items(schema), do: schema

  defp format_content(%Message.Human{content: c}), do: %{role: "user", parts: [%{text: c}]}

  defp format_content(%Message.AI{content: c, tool_calls: []}),
    do: %{role: "model", parts: [%{text: c}]}

  defp format_content(%Message.AI{tool_calls: [%Message.ToolCall{name: n, args: a} | _]}),
    do: %{role: "model", parts: [%{"functionCall" => %{"name" => n, "args" => a}}]}

  defp format_content(%Message.Tool{content: c, tool_call_id: _} = tool) do
    %{
      role: "function",
      parts: [
        %{"functionResponse" => %{"name" => infer_tool_name(tool), "response" => safe_decode(c)}}
      ]
    }
  end

  defp format_content(%{tool_calls: [call | _]}) when is_map(call),
    do: %{
      role: "model",
      parts: [
        %{
          "functionCall" => %{
            "name" => to_string(call[:name] || call["name"]),
            "args" => call[:args] || call["args"] || %{}
          }
        }
      ]
    }

  defp format_content(%{tool_call_id: _, content: c} = tool) do
    %{
      role: "function",
      parts: [
        %{"functionResponse" => %{"name" => infer_tool_name(tool), "response" => safe_decode(c)}}
      ]
    }
  end

  defp format_content(%{content: c, tool_calls: _}),
    do: %{role: "model", parts: [%{text: c || ""}]}

  defp format_content(%{role: _, parts: _} = raw), do: raw
  defp format_content(%{role: r, content: c}), do: %{role: r, parts: [%{text: c}]}
  defp format_content(%{content: c}), do: %{role: "user", parts: [%{text: c}]}

  defp infer_tool_name(%{name: n}) when is_binary(n), do: n
  defp infer_tool_name(%{"name" => n}) when is_binary(n), do: n
  defp infer_tool_name(_), do: "unknown"

  defp safe_decode(c) when is_binary(c) do
    c
    |> Jason.decode()
    |> to_result_map(c)
  end

  defp safe_decode(c), do: %{"result" => inspect(c)}

  defp to_result_map({:ok, map}, _raw) when is_map(map), do: map
  defp to_result_map(_, raw), do: %{"result" => raw}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
