defmodule LangEx.MessageTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph
  alias LangEx.Message

  describe "message construction and reducer" do
    test "creates typed messages and add_messages appends them" do
      initial = [Message.system("You are a bot"), Message.human("Hi")]
      reply = Message.ai("Hello!")

      result = Message.add_messages(initial, [reply])

      assert [
               %Message.System{content: "You are a bot"},
               %Message.Human{content: "Hi"},
               %Message.AI{content: "Hello!"}
             ] = result
    end

    test "add_messages replaces messages with matching IDs" do
      original = [
        Message.human("Draft 1", id: "msg-1"),
        Message.ai("Response", id: "msg-2")
      ]

      correction = [Message.human("Draft 2", id: "msg-1")]

      result = Message.add_messages(original, correction)

      assert [
               %Message.Human{content: "Draft 2", id: "msg-1"},
               %Message.AI{content: "Response", id: "msg-2"}
             ] = result
    end

    test "add_messages appends new messages with IDs not in existing" do
      existing = [Message.human("Hi")]
      new_with_id = [Message.ai("Hello!", id: "fresh-1")]

      result = Message.add_messages(existing, new_with_id)

      assert [
               %Message.Human{content: "Hi"},
               %Message.AI{content: "Hello!", id: "fresh-1"}
             ] = result
    end

    test "add_messages removes a single message by id" do
      existing = [
        Message.human("Keep me", id: "a"),
        Message.ai("Drop me", id: "b"),
        Message.human("Keep me too", id: "c")
      ]

      result = Message.add_messages(existing, [Message.remove("b")])

      assert [
               %Message.Human{content: "Keep me", id: "a"},
               %Message.Human{content: "Keep me too", id: "c"}
             ] = result
    end

    test "remove_all clears history then keeps trailing messages" do
      existing = [Message.human("old 1"), Message.ai("old 2")]

      result = Message.add_messages(existing, [Message.remove_all(), Message.system("summary")])

      assert [%Message.System{content: "summary"}] = result
    end

    test "remove_all with no trailing messages empties the history" do
      existing = [Message.human("old")]

      assert [] = Message.add_messages(existing, Message.remove_all())
    end

    test "removal instructions compose with appends left to right" do
      existing = [Message.human("q", id: "q"), Message.ai("stale", id: "stale")]

      result =
        Message.add_messages(existing, [
          Message.remove("stale"),
          Message.ai("fresh", id: "fresh")
        ])

      assert [
               %Message.Human{content: "q", id: "q"},
               %Message.AI{content: "fresh", id: "fresh"}
             ] = result
    end

    test "message reducer works within a graph pipeline" do
      {:ok, result} =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(:greet, fn _state ->
          %{messages: [Message.ai("Hello there!")]}
        end)
        |> Graph.add_edge(:__start__, :greet)
        |> Graph.add_edge(:greet, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{messages: [Message.human("Hi")]})

      assert %{
               messages: [
                 %Message.Human{content: "Hi"},
                 %Message.AI{content: "Hello there!"}
               ]
             } = result
    end
  end
end
