defmodule LangEx.LLM.Gemini.SSETest do
  use ExUnit.Case, async: true

  alias LangEx.LLM.Gemini.SSE
  alias LangEx.Message

  # streamGenerateContent?alt=sse emits one GenerateContentResponse per data:
  # line. Text lives in candidates[0].content.parts[].text; last chunk carries
  # usageMetadata.promptTokenCount / candidatesTokenCount. No [DONE] sentinel.
  @sse_body """
  data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hel"}]},"index":0}]}

  data: {"candidates":[{"content":{"role":"model","parts":[{"text":"lo"}]},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2,"totalTokenCount":7}}
  """

  test "on_token receives each content delta and the message assembles" do
    test_pid = self()
    callbacks = SSE.callbacks(&send(test_pid, {:token, &1}))

    assert {:ok, %Message.AI{content: "Hello", tool_calls: []},
            %{input_tokens: 5, output_tokens: 2}} =
             SSE.parse_response(@sse_body, callbacks)

    assert_received {:token, "Hel"}
    assert_received {:token, "lo"}
  end

  test "without callbacks the same body parses silently" do
    assert {:ok, %Message.AI{content: "Hello"}, %{input_tokens: 5, output_tokens: 2}} =
             SSE.parse_response(@sse_body, SSE.callbacks(nil))

    refute_received {:token, _}
  end

  test "thought parts are not content and do not fire on_token" do
    body = """
    data: {"candidates":[{"content":{"role":"model","parts":[{"thought":true,"text":"pondering"}]}}]}

    data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":1,"totalTokenCount":6}}
    """

    test_pid = self()

    assert {:ok, %Message.AI{content: "Hello", tool_calls: []},
            %{input_tokens: 5, output_tokens: 1}} =
             SSE.parse_response(body, SSE.callbacks(&send(test_pid, {:token, &1})))

    assert_received {:token, "Hello"}
    refute_received {:token, "pondering"}
  end

  @tool_body """
  data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"get_weather","args":{"location":"Paris"}}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":12,"totalTokenCount":20}}
  """

  test "a whole functionCall assembles one ToolCall and does not fire on_token" do
    test_pid = self()
    callbacks = SSE.callbacks(&send(test_pid, {:token, &1}))

    assert {:ok, %Message.AI{content: nil, tool_calls: [call]},
            %{input_tokens: 8, output_tokens: 12}} =
             SSE.parse_response(@tool_body, callbacks)

    assert %Message.ToolCall{name: "get_weather", id: nil, args: %{"location" => "Paris"}} = call
    refute_received {:token, _}
  end

  test "functionCall id is kept when the API sends one" do
    body = """
    data: {"candidates":[{"content":{"parts":[{"functionCall":{"id":"fc_1","name":"get_weather","args":{"location":"Paris"}}}]}}]}
    """

    assert {:ok, %Message.AI{tool_calls: [call]}, _} =
             SSE.parse_response(body, SSE.callbacks(nil))

    assert %Message.ToolCall{name: "get_weather", id: "fc_1", args: %{"location" => "Paris"}} =
             call
  end

  test "chunks with the same functionCall id merge args" do
    body = """
    data: {"candidates":[{"content":{"parts":[{"functionCall":{"id":"fc_1","name":"get_weather","args":{"location":"Paris"}}}]}}]}

    data: {"candidates":[{"content":{"parts":[{"functionCall":{"id":"fc_1","name":"get_weather","args":{"units":"celsius"}}}]}}]}
    """

    assert {:ok, %Message.AI{tool_calls: [call]}, _} =
             SSE.parse_response(body, SSE.callbacks(nil))

    assert %Message.ToolCall{
             name: "get_weather",
             id: "fc_1",
             args: %{"location" => "Paris", "units" => "celsius"}
           } = call
  end

  @split_tool_body """
  data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"get_weather","args":{"location":"Par"}}}]}}]}

  data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"get_weather","args":{"location":"Paris","units":"celsius"}}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":12,"totalTokenCount":20}}
  """

  test "the same functionCall name across chunks merges args objects" do
    assert {:ok, %Message.AI{tool_calls: [call]}, %{input_tokens: 8, output_tokens: 12}} =
             SSE.parse_response(@split_tool_body, SSE.callbacks(nil))

    assert %Message.ToolCall{
             name: "get_weather",
             args: %{"location" => "Paris", "units" => "celsius"}
           } = call
  end

  test "two functionCall parts in one chunk are two ToolCalls" do
    body = """
    data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"get_weather","args":{"location":"Paris"}}},{"functionCall":{"name":"get_time","args":{"tz":"UTC"}}}]}}]}
    """

    assert {:ok, %Message.AI{tool_calls: [weather, time]}, _} =
             SSE.parse_response(body, SSE.callbacks(nil))

    assert %Message.ToolCall{name: "get_weather", args: %{"location" => "Paris"}} = weather
    assert %Message.ToolCall{name: "get_time", args: %{"tz" => "UTC"}} = time
  end

  test "usageMetadata on the last chunk becomes token counts" do
    assert {:ok, %Message.AI{content: "Hello"}, %{input_tokens: 5, output_tokens: 2}} =
             SSE.parse_response(@sse_body, SSE.callbacks(nil))
  end
end
