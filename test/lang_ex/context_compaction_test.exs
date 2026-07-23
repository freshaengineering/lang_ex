defmodule LangEx.ContextCompactionTest do
  use ExUnit.Case, async: true

  alias LangEx.ContextCompaction
  alias LangEx.Message

  describe "compact_if_needed/2" do
    test "returns messages unchanged when under budget" do
      messages = [
        Message.system("system"),
        Message.human("hello"),
        Message.ai("hi")
      ]

      assert messages == ContextCompaction.compact_if_needed(messages, max_bytes: 100_000)
    end

    test "compacts oldest rounds when over budget" do
      large_content = String.duplicate("x", 5_000)

      messages = [
        Message.system("system"),
        Message.ai("round 1", tool_calls: [%Message.ToolCall{name: "t1", id: "1", args: %{}}]),
        Message.tool(large_content, "1"),
        Message.ai("round 2", tool_calls: [%Message.ToolCall{name: "t2", id: "2", args: %{}}]),
        Message.tool(large_content, "2"),
        Message.ai("round 3", tool_calls: [%Message.ToolCall{name: "t3", id: "3", args: %{}}]),
        Message.tool(large_content, "3"),
        Message.human("continue")
      ]

      compacted = ContextCompaction.compact_if_needed(messages, max_bytes: 12_000)

      assert [%Message.System{}, %Message.Human{} | _rest] = compacted
      assert length(compacted) < length(messages)

      notice = Enum.at(compacted, 1)
      assert %Message.Human{} = notice
      assert String.contains?(notice.content, "Context compacted")
      assert String.contains?(notice.content, "t1")
    end

    test "uses the :summarizer to describe dropped rounds when provided" do
      large_content = String.duplicate("x", 5_000)

      messages = [
        Message.system("system"),
        Message.ai("round 1", tool_calls: [%Message.ToolCall{name: "t1", id: "1", args: %{}}]),
        Message.tool(large_content, "1"),
        Message.ai("round 2", tool_calls: [%Message.ToolCall{name: "t2", id: "2", args: %{}}]),
        Message.tool(large_content, "2"),
        Message.ai("round 3", tool_calls: [%Message.ToolCall{name: "t3", id: "3", args: %{}}]),
        Message.tool(large_content, "3"),
        Message.human("continue")
      ]

      summarizer = fn dropped -> "LLM summary of #{length(dropped)} messages" end

      compacted =
        ContextCompaction.compact_if_needed(messages, max_bytes: 12_000, summarizer: summarizer)

      notice = Enum.at(compacted, 1)
      assert String.contains?(notice.content, "LLM summary of")
    end

    test "preserves at least min_rounds_to_keep" do
      large_content = String.duplicate("x", 5_000)

      messages = [
        Message.system("system"),
        Message.ai("r1", tool_calls: [%Message.ToolCall{name: "t1", id: "1", args: %{}}]),
        Message.tool(large_content, "1"),
        Message.ai("r2", tool_calls: [%Message.ToolCall{name: "t2", id: "2", args: %{}}]),
        Message.tool(large_content, "2")
      ]

      compacted =
        ContextCompaction.compact_if_needed(messages,
          max_bytes: 1,
          min_rounds_to_keep: 2
        )

      assert compacted == messages
    end
  end

  describe "messages_byte_size/1" do
    test "sums content byte sizes" do
      messages = [
        Message.system("abc"),
        Message.human("defgh"),
        Message.ai("ij")
      ]

      assert ContextCompaction.messages_byte_size(messages) == 10
    end

    test "handles nil content" do
      messages = [Message.ai(nil)]
      assert ContextCompaction.messages_byte_size(messages) == 0
    end
  end

  describe "default_error_detector/1" do
    test "detects JSON error key" do
      assert ContextCompaction.default_error_detector(~s({"error": "not found"}))
    end

    test "detects JSON errors key" do
      assert ContextCompaction.default_error_detector(~s({"errors": ["bad"]}))
    end

    test "returns false for non-error JSON" do
      refute ContextCompaction.default_error_detector(~s({"data": "ok"}))
    end

    test "returns false for empty content" do
      refute ContextCompaction.default_error_detector("")
    end
  end

  describe "custom compaction_notice" do
    test "uses custom notice builder" do
      large_content = String.duplicate("x", 5_000)

      messages = [
        Message.system("system"),
        Message.ai("r1", tool_calls: [%Message.ToolCall{name: "t1", id: "1", args: %{}}]),
        Message.tool(large_content, "1"),
        Message.ai("r2", tool_calls: [%Message.ToolCall{name: "t2", id: "2", args: %{}}]),
        Message.tool(large_content, "2"),
        Message.ai("r3", tool_calls: [%Message.ToolCall{name: "t3", id: "3", args: %{}}]),
        Message.tool(large_content, "3")
      ]

      custom_notice = fn summary, count ->
        Message.human("CUSTOM: dropped #{count} rounds. #{summary}")
      end

      compacted =
        ContextCompaction.compact_if_needed(messages,
          max_bytes: 12_000,
          compaction_notice: custom_notice
        )

      notice = Enum.at(compacted, 1)
      assert String.starts_with?(notice.content, "CUSTOM:")
    end
  end
end
