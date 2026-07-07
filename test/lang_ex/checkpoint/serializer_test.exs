defmodule LangEx.Checkpoint.SerializerTest do
  use ExUnit.Case, async: true

  alias LangEx.Checkpoint
  alias LangEx.Checkpoint.Serializer
  alias LangEx.Message

  describe "round-trip through JSON" do
    test "primitives survive unchanged" do
      assert round_trip(nil) == nil
      assert round_trip(true) == true
      assert round_trip(42) == 42
      assert round_trip(3.14) == 3.14
      assert round_trip("hello") == "hello"
    end

    test "atoms, tuples, and non-UTF8 binaries are restored exactly" do
      assert round_trip(:pending) == :pending
      assert round_trip({:ok, :done, 3}) == {:ok, :done, 3}
      assert round_trip(<<0, 255, 1>>) == <<0, 255, 1>>
    end

    test "message structs in state pattern-match after restore" do
      state = %{
        messages: [
          Message.human("hi", id: "m1"),
          Message.ai(nil,
            id: "m2",
            tool_calls: [%Message.ToolCall{name: "search", id: "t1", args: %{"q" => "x"}}]
          ),
          Message.tool(~s({"result": 1}), "t1")
        ],
        step_count: 2
      }

      assert %{
               messages: [
                 %Message.Human{content: "hi"},
                 %Message.AI{
                   tool_calls: [%Message.ToolCall{name: "search", args: %{"q" => "x"}}]
                 },
                 %Message.Tool{tool_call_id: "t1"}
               ],
               step_count: 2
             } = round_trip(state)
    end

    test "maps keep atom and non-string keys" do
      assert round_trip(%{"raw" => 2, {:a, 1} => 3, count: 1}) ==
               %{"raw" => 2, {:a, 1} => 3, count: 1}
    end

    test "full checkpoint struct round-trips including DateTime" do
      cp =
        Checkpoint.new(
          thread_id: "t-1",
          state: %{value: 7},
          next_nodes: [:worker],
          step: 3,
          metadata: %{},
          pending_interrupts: [%{value: "approve?", node: :check}]
        )

      assert %Checkpoint{
               thread_id: "t-1",
               state: %{value: 7},
               next_nodes: [:worker],
               step: 3,
               pending_interrupts: [%{value: "approve?", node: :check}],
               created_at: %DateTime{}
             } = round_trip(cp)
    end

    test "decoding never creates new atoms" do
      payload =
        Jason.encode!(%{"~a" => "definitely_not_an_existing_atom_#{System.unique_integer()}"})

      assert_raise ArgumentError, fn ->
        payload |> Jason.decode!() |> Serializer.decode()
      end
    end

    test "functions are rejected at encode time" do
      assert_raise ArgumentError, ~r/cannot serialize/, fn ->
        Serializer.encode(%{callback: fn -> :ok end})
      end
    end
  end

  defp round_trip(term) do
    term
    |> Serializer.encode()
    |> Jason.encode!()
    |> Jason.decode!()
    |> Serializer.decode()
  end
end
