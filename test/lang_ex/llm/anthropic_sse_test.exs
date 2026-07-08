defmodule LangEx.LLM.Anthropic.SSETest do
  use ExUnit.Case, async: true

  alias LangEx.LLM.Anthropic.SSE
  alias LangEx.Message

  @sse_body """
  data: {"type":"message_start","message":{"usage":{"input_tokens":12}}}

  data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}

  data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}

  data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}

  data: {"type":"message_delta","usage":{"output_tokens":2}}
  """

  test "on_token receives each content delta and the message assembles" do
    test_pid = self()
    callbacks = SSE.callbacks(nil, &send(test_pid, {:token, &1}))

    assert {:ok, %Message.AI{content: "Hello"}, %{input_tokens: 12, output_tokens: 2}} =
             SSE.parse_response(@sse_body, callbacks)

    assert_received {:token, "Hel"}
    assert_received {:token, "lo"}
  end

  test "without callbacks the same body parses silently" do
    assert {:ok, %Message.AI{content: "Hello"}, _usage} =
             SSE.parse_response(@sse_body, SSE.callbacks(nil, nil))

    refute_received {:token, _}
  end
end
