defmodule LangEx.Eval.TrajectoryTest do
  use ExUnit.Case, async: true

  alias LangEx.Checkpoint
  alias LangEx.Eval.Trajectory
  alias LangEx.Message

  describe "from_messages/1" do
    test "flattens tool calls from every AI turn in history order" do
      messages = [
        Message.system("be helpful"),
        Message.human("weather in Paris and London?"),
        Message.ai(nil,
          tool_calls: [
            %Message.ToolCall{name: "get_weather", id: "c1", args: %{"city" => "Paris"}},
            %Message.ToolCall{name: "get_weather", id: "c2", args: %{"city" => "London"}}
          ]
        ),
        Message.tool("sunny", "c1"),
        Message.tool("rainy", "c2"),
        Message.human("double check London please"),
        Message.ai("Checking the forecast.",
          tool_calls: [
            %Message.ToolCall{name: "get_forecast", id: "c3", args: %{"city" => "London"}}
          ]
        ),
        Message.tool("rain all week", "c3"),
        Message.ai("Paris is sunny, London is rainy.")
      ]

      assert [
               %{name: "get_weather", args: %{"city" => "Paris"}},
               %{name: "get_weather", args: %{"city" => "London"}},
               %{name: "get_forecast", args: %{"city" => "London"}}
             ] = Trajectory.from_messages(messages)
    end

    test "returns an empty trajectory when no AI turn carries tool calls" do
      messages = [
        Message.human("hello"),
        Message.ai("hi there"),
        Message.human("bye"),
        Message.ai("goodbye")
      ]

      assert [] = Trajectory.from_messages(messages)
    end
  end

  describe "from_checkpoint/1" do
    test "extracts steps from the checkpoint's state messages" do
      checkpoint =
        Checkpoint.new(
          thread_id: "t1",
          state: %{
            messages: [
              Message.human("find elixir docs"),
              Message.ai(nil,
                tool_calls: [
                  %Message.ToolCall{name: "search", id: "c1", args: %{"q" => "elixir"}}
                ]
              ),
              Message.tool("found", "c1")
            ]
          },
          next_nodes: [],
          step: 1,
          metadata: %{}
        )

      assert [%{name: "search", args: %{"q" => "elixir"}}] =
               Trajectory.from_checkpoint(checkpoint)
    end

    test "returns an empty trajectory when state has no messages key" do
      checkpoint =
        Checkpoint.new(
          thread_id: "t1",
          state: %{counter: 3},
          next_nodes: [],
          step: 0,
          metadata: %{}
        )

      assert [] = Trajectory.from_checkpoint(checkpoint)
    end
  end

  describe "match/3 in :strict mode" do
    test "passes on the same steps in the same order" do
      actual = [
        %{name: "search", args: %{"q" => "elixir"}},
        %{name: "fetch", args: %{"id" => 1}}
      ]

      assert %{match?: true, missing: [], unexpected: [], detail: detail} =
               Trajectory.match(actual, [%{name: "search"}, %{name: "fetch"}], mode: :strict)

      assert detail =~ "strict"
    end

    test "fails when the order differs" do
      actual = [
        %{name: "fetch", args: %{"id" => 1}},
        %{name: "search", args: %{"q" => "elixir"}}
      ]

      assert %{match?: false, detail: detail} =
               Trajectory.match(actual, [%{name: "search"}, %{name: "fetch"}], mode: :strict)

      assert detail =~ "mismatch in strict mode"
    end

    test "fails when the lengths differ" do
      actual = [
        %{name: "search", args: %{"q" => "elixir"}},
        %{name: "fetch", args: %{"id" => 1}}
      ]

      assert %{match?: false, missing: [], unexpected: [%{name: "fetch"}]} =
               Trajectory.match(actual, [%{name: "search"}], mode: :strict)
    end
  end

  describe "match/3 in :unordered mode" do
    test "passes on the same steps in any order" do
      actual = [
        %{name: "fetch", args: %{"id" => 1}},
        %{name: "search", args: %{"q" => "elixir"}}
      ]

      assert %{match?: true, missing: [], unexpected: []} =
               Trajectory.match(actual, [%{name: "search"}, %{name: "fetch"}], mode: :unordered)
    end

    test "fails when the counts differ" do
      actual = [
        %{name: "search", args: %{"q" => "elixir"}},
        %{name: "search", args: %{"q" => "erlang"}}
      ]

      assert %{match?: false, missing: [], unexpected: [%{args: %{"q" => "erlang"}}]} =
               Trajectory.match(actual, [%{name: "search"}], mode: :unordered)
    end
  end

  describe "match/3 in :subset mode" do
    test "passes with extra actual steps and reports them as unexpected" do
      actual = [
        %{name: "search", args: %{"q" => "elixir"}},
        %{name: "log", args: %{"level" => "debug"}},
        %{name: "fetch", args: %{"id" => 1}}
      ]

      assert %{match?: true, missing: [], unexpected: [%{name: "log"}], detail: detail} =
               Trajectory.match(actual, [%{name: "search"}, %{name: "fetch"}], mode: :subset)

      assert detail =~ "extra steps [log]"
    end

    test "fails when an expected step is missing" do
      actual = [%{name: "search", args: %{"q" => "elixir"}}]

      assert %{match?: false, missing: [%{name: "fetch"}], detail: detail} =
               Trajectory.match(actual, [%{name: "search"}, %{name: "fetch"}], mode: :subset)

      assert detail =~ "missing [fetch]"
    end

    test "is the default mode" do
      actual = [
        %{name: "search", args: %{"q" => "elixir"}},
        %{name: "log", args: %{}}
      ]

      assert %{match?: true, unexpected: [%{name: "log"}]} =
               Trajectory.match(actual, [%{name: "search"}])
    end
  end

  describe "match/3 args matching" do
    test "passes when expected args are a subset of actual args" do
      actual = [%{name: "search", args: %{"q" => "elixir", "limit" => 10}}]

      assert %{match?: true} =
               Trajectory.match(actual, [%{name: "search", args: %{"q" => "elixir"}}])
    end

    test "fails when an expected arg value differs" do
      actual = [%{name: "search", args: %{"q" => "elixir", "limit" => 10}}]

      assert %{match?: false, missing: [%{name: "search", args: %{"q" => "erlang"}}]} =
               Trajectory.match(actual, [%{name: "search", args: %{"q" => "erlang"}}])
    end

    test "fails when an expected arg key is absent from actual args" do
      actual = [%{name: "search", args: %{"q" => "elixir"}}]

      assert %{match?: false, missing: [%{name: "search"}]} =
               Trajectory.match(actual, [%{name: "search", args: %{"limit" => 10}}])
    end
  end

  describe "match/3 with duplicate expected steps" do
    test "each duplicate requires a distinct actual step" do
      actual = [%{name: "fetch", args: %{"id" => 1}}]

      assert %{match?: false, missing: [%{name: "fetch"}]} =
               Trajectory.match(actual, [%{name: "fetch"}, %{name: "fetch"}], mode: :subset)
    end

    test "duplicates pass when enough distinct actual steps exist" do
      actual = [
        %{name: "fetch", args: %{"id" => 1}},
        %{name: "fetch", args: %{"id" => 2}}
      ]

      assert %{match?: true, missing: [], unexpected: []} =
               Trajectory.match(actual, [%{name: "fetch"}, %{name: "fetch"}], mode: :unordered)
    end
  end
end
