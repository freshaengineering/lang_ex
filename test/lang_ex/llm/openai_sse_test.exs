defmodule LangEx.LLM.OpenAI.SSETest do
  use ExUnit.Case, async: true

  alias LangEx.LLM.OpenAI.SSE
  alias LangEx.Message

  # Official CreateChatCompletionStreamResponse shape: first chunk often has
  # role + empty content, usage is null until the final choices:[] chunk, then
  # data: [DONE]. See OpenAPI ChatCompletionStreamOptions.include_usage.
  @sse_body """
  data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}],"usage":null}

  data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"content":"Hel"},"logprobs":null,"finish_reason":null}],"usage":null}

  data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"content":"lo"},"logprobs":null,"finish_reason":null}],"usage":null}

  data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}],"usage":null}

  data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-4o-mini","choices":[],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}

  data: [DONE]
  """

  test "on_token receives each content delta and the message assembles" do
    test_pid = self()
    callbacks = SSE.callbacks(&send(test_pid, {:token, &1}))

    assert {:ok, %Message.AI{content: "Hello", tool_calls: []},
            %{input_tokens: 4, output_tokens: 2}} =
             SSE.parse_response(@sse_body, callbacks)

    assert_received {:token, "Hel"}
    assert_received {:token, "lo"}
    refute_received {:token, ""}
  end

  test "without callbacks the same body parses silently" do
    assert {:ok, %Message.AI{content: "Hello"}, %{input_tokens: 4, output_tokens: 2}} =
             SSE.parse_response(@sse_body, SSE.callbacks(nil))

    refute_received {:token, _}
  end

  test "null content and empty first-chunk content are not tokens" do
    body = """
    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"role":"assistant","content":null},"finish_reason":null}],"usage":null}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}],"usage":null}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1,"model":"gpt-4o-mini","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}

    data: [DONE]
    """

    test_pid = self()

    assert {:ok, %Message.AI{content: "Hi"}, %{input_tokens: 1, output_tokens: 1}} =
             SSE.parse_response(body, SSE.callbacks(&send(test_pid, {:token, &1})))

    assert_received {:token, "Hi"}
    refute_received {:token, _}
  end

  @tool_body """
  data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}],"usage":null}

  data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"location\\":"}}]},"finish_reason":null}],"usage":null}

  data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"Paris\\"}"}}]},"finish_reason":null}],"usage":null}

  data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":null}

  data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1,"model":"gpt-4o-mini","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":8,"total_tokens":18}}

  data: [DONE]
  """

  test "tool-call argument fragments assemble one ToolCall and never fire on_token" do
    test_pid = self()
    callbacks = SSE.callbacks(&send(test_pid, {:token, &1}))

    assert {:ok, %Message.AI{content: nil, tool_calls: [call]},
            %{input_tokens: 10, output_tokens: 8}} =
             SSE.parse_response(@tool_body, callbacks)

    assert %Message.ToolCall{name: "get_weather", id: "call_1", args: %{"location" => "Paris"}} =
             call

    refute_received {:token, _}
  end

  test "[DONE] is ignored even when it is the only payload" do
    assert {:ok, %Message.AI{content: nil, tool_calls: []}, %{input_tokens: 0, output_tokens: 0}} =
             SSE.parse_response("data: [DONE]\n", SSE.callbacks(nil))
  end

  test "usage is taken from the final choices:[] chunk" do
    assert {:ok, %Message.AI{content: "Hello"}, %{input_tokens: 4, output_tokens: 2}} =
             SSE.parse_response(@sse_body, SSE.callbacks(nil))
  end
end
