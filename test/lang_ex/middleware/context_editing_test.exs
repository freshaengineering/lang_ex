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

      mw = ContextEditing.new(keep_last: 1, clear_at_chars: 10, trigger_at_chars: 0)

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

      mw = ContextEditing.new(keep_last: 1, clear_at_chars: 10, trigger_at_chars: 0)

      assert %{} == mw.before_model.(%{messages: messages})
    end

    test "is idempotent — a cleared result is not re-cleared" do
      messages = [
        Message.human("q"),
        Message.tool(String.duplicate("A", 100), "c1"),
        Message.tool("recent", "c2")
      ]

      mw = ContextEditing.new(keep_last: 1, clear_at_chars: 10, trigger_at_chars: 0)

      %{messages: [_remove | edited]} = mw.before_model.(%{messages: messages})

      assert %{} == mw.before_model.(%{messages: edited})
    end

    test "leaves the conversation untouched below the trigger size" do
      messages = [
        Message.human("q"),
        Message.tool(String.duplicate("A", 100), "c1"),
        Message.tool(String.duplicate("B", 100), "c2")
      ]

      mw = ContextEditing.new(keep_last: 1, clear_at_chars: 10, trigger_at_chars: 1_000)

      assert %{} == mw.before_model.(%{messages: messages})
    end

    test "clears every eligible result in one pass once the trigger is crossed" do
      messages = [
        Message.human("q"),
        Message.tool(String.duplicate("A", 400), "c1"),
        Message.tool(String.duplicate("B", 400), "c2"),
        Message.tool(String.duplicate("C", 400), "c3")
      ]

      mw = ContextEditing.new(keep_last: 1, clear_at_chars: 10, trigger_at_chars: 1_000)

      assert %{messages: [%Message.RemoveMessage{} | edited]} =
               mw.before_model.(%{messages: messages})

      assert %Message.Tool{content: "[cleared" <> _} = Enum.at(edited, 1)
      assert %Message.Tool{content: "[cleared" <> _} = Enum.at(edited, 2)
      assert %Message.Tool{content: <<"CCC", _::binary>>} = Enum.at(edited, 3)
    end
  end
end
