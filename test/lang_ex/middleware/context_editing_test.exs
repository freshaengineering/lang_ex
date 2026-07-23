defmodule LangEx.Middleware.ContextEditingTest do
  use ExUnit.Case, async: true

  alias LangEx.Message
  alias LangEx.Middleware.ContextEditing

  describe "before_model hook" do
    test "clears large stale tool results but keeps the most recent" do
      messages = [
        Message.human("q"),
        Message.tool(String.duplicate("A", 100), "c1"),
        Message.tool(String.duplicate("B", 100), "c2"),
        Message.tool(String.duplicate("C", 100), "c3")
      ]

      mw = ContextEditing.new(keep_last: 1, clear_at_chars: 10)

      update = mw.before_model.(%{messages: messages})

      assert [%Message.RemoveMessage{} | edited] = update.messages

      assert %Message.Tool{content: "[cleared" <> _, tool_call_id: "c1"} = Enum.at(edited, 1)
      assert %Message.Tool{content: "[cleared" <> _, tool_call_id: "c2"} = Enum.at(edited, 2)
      assert %Message.Tool{content: <<"CCC", _::binary>>, tool_call_id: "c3"} = Enum.at(edited, 3)
    end

    test "leaves small tool results alone" do
      messages = [
        Message.human("q"),
        Message.tool("tiny", "c1"),
        Message.tool("also tiny", "c2")
      ]

      mw = ContextEditing.new(keep_last: 1, clear_at_chars: 10)

      assert %{} == mw.before_model.(%{messages: messages})
    end

    test "is idempotent — a cleared result is not re-cleared" do
      messages = [
        Message.human("q"),
        Message.tool(String.duplicate("A", 100), "c1"),
        Message.tool("recent", "c2")
      ]

      mw = ContextEditing.new(keep_last: 1, clear_at_chars: 10)

      %{messages: [_remove | edited]} = mw.before_model.(%{messages: messages})

      assert %{} == mw.before_model.(%{messages: edited})
    end
  end
end
