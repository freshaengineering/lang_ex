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

  @thinking_body """
  data: {"type":"message_start","message":{"usage":{"input_tokens":5}}}

  data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}

  data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"pondering..."}}

  data: {"type":"content_block_start","index":1,"content_block":{"type":"text"}}

  data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Answer"}}

  data: {"type":"message_delta","usage":{"output_tokens":3}}
  """

  test "thinking text lands on the AI message (and stays out of the API echo path)" do
    assert {:ok, %Message.AI{content: "Answer", thinking: "pondering..."}, usage} =
             SSE.parse_response(@thinking_body, SSE.callbacks(nil, nil))

    assert usage.thinking == "pondering..."
  end

  test "a reply without thinking carries thinking: nil" do
    assert {:ok, %Message.AI{thinking: nil}, _usage} =
             SSE.parse_response(@sse_body, SSE.callbacks(nil, nil))
  end
end
