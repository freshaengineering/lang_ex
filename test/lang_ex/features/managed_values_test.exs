defmodule LangEx.Features.ManagedValuesTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph

  describe "managed values (remaining_steps)" do
    test "remaining_steps is injected and decrements each step" do
      {:ok, result} =
        Graph.new(counter: {0, fn _old, new -> new end}, seen: {[], &Kernel.++/2})
        |> Graph.add_node(:track, fn state ->
          remaining = state.remaining_steps
          %{counter: state.counter + 1, seen: [remaining]}
        end)
        |> Graph.add_edge(:__start__, :track)
        |> Graph.add_conditional_edges(:track, fn
          %{counter: c} when c >= 3 -> :__end__
          _ -> :track
        end)
        |> Graph.compile()
        |> LangEx.invoke(%{}, recursion_limit: 10)

      assert %{counter: 3, seen: [10, 9, 8]} = result
      refute Map.has_key?(result, :remaining_steps)
    end

    test "a schema-declared :remaining_steps key is left to the user" do
      {:ok, result} =
        Graph.new(remaining_steps: 99, doubled: nil)
        |> Graph.add_node(:use_own, fn state ->
          %{doubled: state.remaining_steps * 2}
        end)
        |> Graph.add_edge(:__start__, :use_own)
        |> Graph.add_edge(:use_own, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{})

      assert %{remaining_steps: 99, doubled: 198} = result
    end
  end

  describe "managed values (is_last_step)" do
    test "is_last_step flips true on the final allowed step" do
      {:ok, result} =
        Graph.new(seen: {[], &Kernel.++/2}, counter: {0, fn _old, new -> new end})
        |> Graph.add_node(:track, fn state ->
          %{counter: state.counter + 1, seen: [state.is_last_step]}
        end)
        |> Graph.add_edge(:__start__, :track)
        |> Graph.add_conditional_edges(:track, fn
          %{counter: c} when c >= 3 -> :__end__
          _ -> :track
        end)
        |> Graph.compile()
        |> LangEx.invoke(%{}, recursion_limit: 3)

      assert %{seen: [false, false, true]} = result
      refute Map.has_key?(result, :is_last_step)
    end
  end

  describe "managed values (deadline / remaining_ms)" do
    test "a future deadline exposes remaining_ms and does not flip is_last_step" do
      {:ok, result} =
        Graph.new(seen: nil)
        |> Graph.add_node(:track, fn state ->
          %{seen: {state.remaining_ms, state.is_last_step}}
        end)
        |> Graph.add_edge(:__start__, :track)
        |> Graph.add_edge(:track, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{}, recursion_limit: 100, deadline_ms: 60_000)

      assert {remaining, false} = result.seen
      assert remaining > 0
      refute Map.has_key?(result, :remaining_ms)
    end

    test "an elapsed deadline flips is_last_step and zeroes remaining_ms" do
      {:ok, result} =
        Graph.new(seen: nil)
        |> Graph.add_node(:track, fn state ->
          %{seen: {state.remaining_ms, state.is_last_step}}
        end)
        |> Graph.add_edge(:__start__, :track)
        |> Graph.add_edge(:track, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{}, recursion_limit: 100, deadline_ms: 0)

      assert {0, true} = result.seen
    end
  end

  describe "managed values (token_budget / remaining_tokens)" do
    test "remaining_tokens tracks llm_usage and is_last_step flips when spent" do
      {:ok, result} =
        Graph.new(
          llm_usage: {%{}, &LangEx.LLM.ChatModel.merge_usage/2},
          rounds: {[], &Kernel.++/2},
          counter: {0, fn _old, new -> new end}
        )
        |> Graph.add_node(:spend, fn state ->
          %{
            counter: state.counter + 1,
            rounds: [{state.remaining_tokens, state.is_last_step}],
            llm_usage: %{output_tokens: 40}
          }
        end)
        |> Graph.add_edge(:__start__, :spend)
        |> Graph.add_conditional_edges(:spend, fn
          %{counter: c} when c >= 4 -> :__end__
          _ -> :spend
        end)
        |> Graph.compile()
        |> LangEx.invoke(%{}, recursion_limit: 100, token_budget: 100)

      assert [{100, false}, {60, false}, {20, false}, {0, true}] = result.rounds
      refute Map.has_key?(result, :remaining_tokens)
    end
  end
end
