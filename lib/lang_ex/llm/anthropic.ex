defmodule LangEx.LLM.Anthropic do
  @moduledoc """
  Streaming Anthropic Claude adapter with tool use, thinking, and prompt caching.

  Uses `stream: true` by default so data flows continuously, resetting
  the TCP receive timeout with each SSE chunk and avoiding idle-connection
  timeouts from intermediary infrastructure.

  ## Features

  - **Streaming** — SSE-based streaming avoids TCP idle timeouts on long requests
  - **Adaptive thinking** — pass `thinking: true` to enable Claude's extended thinking;
    stream thinking deltas in real time via the `on_thinking` callback
  - **Prompt caching** — system prompts and the last tool definition are annotated
    with `cache_control` for Anthropic's prompt caching beta
  - **Usage tracking** — `chat_with_usage/2` returns token counts including cache metrics
  - **Model-aware defaults** — `max_tokens` defaults based on model family

  ## Tool Calling

  Pass `:tools` (list of `%LangEx.Tool{}`) to enable tool calling.
  The adapter returns `{:ok, %Message.AI{tool_calls: [...]}}` when the
  model requests tool use. Use `LangEx.Tool.Node` to execute them.

      LangEx.LLM.Anthropic.chat(messages,
        model: "claude-sonnet-4-20250514",
        tools: [%LangEx.Tool{name: "get_weather", ...}]
      )

  ## Options

  - `:thinking` — enable adaptive thinking (`true` / `false`, default `false`)
  - `:on_thinking` — `fn(accumulated_thinking_text) -> any()` callback
  - `:on_token` — `fn(text_delta) -> any()` callback invoked per streamed
    content token (used by graph streaming's `:messages` mode)
  - `:prompt_caching` — enable prompt caching headers (default `true`)
  - `:stream` — use SSE streaming (default `true`); set `false` for simple requests
  - `:max_tokens` — override max tokens (defaults: 64K for sonnet, 128K otherwise)
  """

  @behaviour LangEx.LLM

  alias LangEx.Config
  alias LangEx.LLM.Anthropic.Formatter
  alias LangEx.LLM.Anthropic.SSE
  alias LangEx.Message
  alias LangEx.Tool

  @base_url "https://api.anthropic.com/v1"
  @api_version "2023-06-01"
  @prompt_caching_beta "prompt-caching-2024-07-31"

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
    api_key = Config.api_key!(:anthropic, opts)
    model = Config.model(:anthropic, opts)
    tools = Keyword.get(opts, :tools, [])
    thinking? = Keyword.get(opts, :thinking, false)
    callbacks = SSE.callbacks(Keyword.get(opts, :on_thinking), Keyword.get(opts, :on_token))
    caching? = Keyword.get(opts, :prompt_caching, true)
    stream? = Keyword.get(opts, :stream, true)

    {system_prompt, conversation} = Formatter.extract_system(messages)

    body =
      %{
        model: model,
        messages: Enum.map(conversation, &Formatter.format_message/1),
        max_tokens: opts[:max_tokens] || default_max_tokens(model)
      }
      |> put_stream(stream?)
      |> put_thinking(thinking?, opts)
      |> put_system(system_prompt, caching?)
      |> put_tools(tools, caching?)

    send_request(body, api_key, callbacks, caching?)
  end

  defp put_stream(body, true), do: Map.put(body, :stream, true)
  defp put_stream(body, false), do: body

  defp put_thinking(body, true, _opts), do: Map.put(body, :thinking, %{type: "adaptive"})
  defp put_thinking(body, false, opts), do: put_present(body, :temperature, opts[:temperature])

  defp send_request(body, api_key, callbacks, caching?) do
    [
      json: body,
      headers: build_headers(api_key, caching?),
      receive_timeout: 300_000,
      pool_timeout: 60_000
    ]
    |> dispatch_request(callbacks, body[:stream])
  end

  defp build_headers(api_key, caching?) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"content-type", "application/json"}
    ]
    |> add_caching_header(caching?)
  end

  defp dispatch_request(req_opts, callbacks, _stream? = true)
       when is_function(:erlang.map_get(:on_thinking, callbacks), 1)
       when is_function(:erlang.map_get(:on_token, callbacks), 1),
       do: stream_request(req_opts, callbacks)

  defp dispatch_request(req_opts, callbacks, _stream?),
    do: batch_request(req_opts, callbacks)

  defp add_caching_header(headers, true),
    do: headers ++ [{"anthropic-beta", @prompt_caching_beta}]

  defp add_caching_header(headers, false), do: headers

  defp stream_request(req_opts, callbacks) do
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
      |> then(&Req.post("#{@base_url}/messages", &1))
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

  defp handle_streaming_response(
         {:ok, %{status: 200, body: %{"content" => _} = json_resp}},
         _pkey,
         _callbacks
       ),
       do: parse_json_response(json_resp)

  defp handle_streaming_response({:ok, %{status: status, body: resp_body}}, _pkey, _callbacks),
    do: {:error, {status, resp_body}}

  defp handle_streaming_response({:error, reason}, _pkey, _callbacks),
    do: {:error, reason}

  defp batch_request(req_opts, callbacks) do
    "#{@base_url}/messages"
    |> Req.post(req_opts)
    |> handle_batch_response(callbacks)
  end

  defp handle_batch_response({:ok, %{status: 200, body: raw}}, callbacks) when is_binary(raw),
    do: SSE.parse_response(raw, callbacks)

  defp handle_batch_response(
         {:ok, %{status: 200, body: %{"content" => _} = json_resp}},
         _callbacks
       ),
       do: parse_json_response(json_resp)

  defp handle_batch_response({:ok, %{status: status, body: resp_body}}, _callbacks),
    do: {:error, {status, resp_body}}

  defp handle_batch_response({:error, reason}, _callbacks),
    do: {:error, reason}

  defp parse_json_response(%{"content" => content, "usage" => usage}) when is_list(content) do
    parse_json_content(content, extract_usage(usage))
  end

  defp parse_json_response(%{"content" => content}) when is_list(content) do
    parse_json_content(content, %{input_tokens: 0, output_tokens: 0})
  end

  defp parse_json_response(_), do: {:error, :unexpected_response}

  defp parse_json_content(content, usage) do
    content
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> build_json_response(content, usage)
  end

  defp build_json_response([_ | _] = tool_uses, content, usage) do
    text =
      content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])

    calls =
      Enum.map(tool_uses, fn %{"id" => id, "name" => name, "input" => input} ->
        %Message.ToolCall{name: name, id: id, args: input}
      end)

    {:ok, Message.ai(text, tool_calls: calls), usage}
  end

  defp build_json_response([], content, usage) do
    {:ok,
     content
     |> Enum.find(&(&1["type"] == "text"))
     |> extract_text_content()
     |> Message.ai(), usage}
  end

  defp extract_text_content(%{"text" => t}), do: t
  defp extract_text_content(_), do: ""

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

  defp default_max_tokens(model) when is_binary(model) do
    model
    |> String.contains?("sonnet")
    |> max_tokens_for_family()
  end

  defp default_max_tokens(_), do: 128_000

  defp max_tokens_for_family(true), do: 64_000
  defp max_tokens_for_family(false), do: 128_000

  defp put_system(body, nil, _caching?), do: body

  defp put_system(body, prompt, true) do
    Map.put(body, :system, [
      %{
        "type" => "text",
        "text" => prompt,
        "cache_control" => %{"type" => "ephemeral"}
      }
    ])
  end

  defp put_system(body, prompt, false), do: Map.put(body, :system, prompt)

  defp put_tools(body, [], _caching?), do: body

  defp put_tools(body, tools, _caching? = true) do
    tools
    |> Enum.map(&format_tool/1)
    |> mark_last_cacheable()
    |> then(&Map.put(body, :tools, &1))
  end

  defp put_tools(body, tools, _caching?) do
    Map.put(body, :tools, Enum.map(tools, &format_tool/1))
  end

  defp mark_last_cacheable([]), do: []

  defp mark_last_cacheable(tools) do
    {init, [last]} = Enum.split(tools, length(tools) - 1)
    init ++ [Map.put(last, :cache_control, %{"type" => "ephemeral"})]
  end

  defp format_tool(%Tool{name: n, description: d, parameters: p}),
    do: %{name: n, description: d, input_schema: p}

  defp format_tool(raw), do: raw

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
