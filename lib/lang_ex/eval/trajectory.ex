defmodule LangEx.Eval.Trajectory do
  @moduledoc """
  Extraction and matching of agent tool-call trajectories.

  A trajectory is the ordered list of tool calls an agent made during a
  run. It can be extracted from a message history or a saved checkpoint,
  then compared against an expected trajectory to make agent regressions
  CI-testable (the agentevals pattern).
  """

  alias LangEx.Checkpoint
  alias LangEx.Message

  @type step :: %{name: String.t(), args: map()}
  @type expected_step :: %{required(:name) => String.t(), optional(:args) => map()}
  @type mode :: :strict | :unordered | :subset
  @type match_result :: %{
          match?: boolean(),
          missing: [expected_step()],
          unexpected: [step()],
          detail: String.t()
        }

  @doc """
  Extract the tool-call trajectory from a message history.

  Walks the history in order and flattens every AI turn's tool calls
  into `%{name: name, args: args}` steps.
  """
  @spec from_messages([Message.t()]) :: [step()]
  def from_messages(messages), do: Enum.flat_map(messages, &steps_from_message/1)

  @doc """
  Extract the tool-call trajectory from a checkpoint's state messages.

  Returns `[]` when the checkpoint state carries no `:messages` key.
  """
  @spec from_checkpoint(Checkpoint.t()) :: [step()]
  def from_checkpoint(%Checkpoint{state: state}) when is_map(state) do
    state
    |> Map.get(:messages, [])
    |> from_messages()
  end

  def from_checkpoint(%Checkpoint{}), do: []

  @doc """
  Match an actual trajectory against an expected one.

  An expected step matches an actual step when their names are equal and
  every key-value pair in the expected `:args` (when given) equals the
  actual args value — partial args matching. Each expected step consumes
  a distinct actual step, so duplicated expected steps require as many
  matching actual steps.

  ## Options

  - `:mode` - `:strict` (same steps, same order, same length),
    `:unordered` (same steps in any order), or `:subset` (every expected
    step present; extra actual steps are reported in `:unexpected` but do
    not fail the match). Defaults to `:subset`.
  """
  @spec match([step()], [expected_step()], keyword()) :: match_result()
  def match(actual, expected, opts \\ []) do
    opts
    |> Keyword.get(:mode, :subset)
    |> run_match(actual, expected)
  end

  defp steps_from_message(%Message.AI{tool_calls: calls}) when is_list(calls),
    do: Enum.map(calls, &%{name: &1.name, args: &1.args})

  defp steps_from_message(_message), do: []

  defp run_match(:strict, actual, expected) do
    actual
    |> positional_diff(expected)
    |> strict_result()
  end

  defp run_match(:unordered, actual, expected) do
    expected
    |> consume(actual)
    |> unordered_result()
  end

  defp run_match(:subset, actual, expected) do
    expected
    |> consume(actual)
    |> subset_result()
  end

  defp strict_result({[], []}), do: result(true, [], [], :strict)
  defp strict_result({missing, unexpected}), do: result(false, missing, unexpected, :strict)

  defp unordered_result({[], []}), do: result(true, [], [], :unordered)
  defp unordered_result({missing, leftovers}), do: result(false, missing, leftovers, :unordered)

  defp subset_result({[], leftovers}), do: result(true, [], leftovers, :subset)
  defp subset_result({missing, leftovers}), do: result(false, missing, leftovers, :subset)

  defp result(match?, missing, unexpected, mode) do
    %{
      match?: match?,
      missing: missing,
      unexpected: unexpected,
      detail: detail(match?, missing, unexpected, mode)
    }
  end

  defp detail(true, _missing, [], mode), do: "trajectory matches in #{mode} mode"

  defp detail(true, _missing, unexpected, mode),
    do: "trajectory matches in #{mode} mode with extra steps #{names(unexpected)}"

  defp detail(false, missing, unexpected, mode),
    do:
      "trajectory mismatch in #{mode} mode: missing #{names(missing)}, unexpected #{names(unexpected)}"

  defp names(steps), do: "[" <> Enum.map_join(steps, ", ", & &1.name) <> "]"

  defp positional_diff(actual, expected) do
    pairs = pad_pairs(expected, actual)

    {Enum.flat_map(pairs, &missing_at_position/1),
     Enum.flat_map(pairs, &unexpected_at_position/1)}
  end

  defp pad_pairs(expected, actual) do
    Enum.map(
      0..(max(length(expected), length(actual)) - 1)//1,
      &{Enum.at(expected, &1, :none), Enum.at(actual, &1, :none)}
    )
  end

  defp missing_at_position({:none, _actual_step}), do: []
  defp missing_at_position({expected_step, :none}), do: [expected_step]

  defp missing_at_position({expected_step, actual_step}),
    do: rejected(step_matches?(expected_step, actual_step), expected_step)

  defp unexpected_at_position({_expected_step, :none}), do: []
  defp unexpected_at_position({:none, actual_step}), do: [actual_step]

  defp unexpected_at_position({expected_step, actual_step}),
    do: rejected(step_matches?(expected_step, actual_step), actual_step)

  defp rejected(true, _step), do: []
  defp rejected(false, step), do: [step]

  defp consume(expected, actual) do
    expected
    |> Enum.reduce({[], actual}, &consume_step/2)
    |> reorder_missing()
  end

  defp reorder_missing({missing, leftovers}), do: {Enum.reverse(missing), leftovers}

  defp consume_step(expected_step, {missing, remaining}) do
    remaining
    |> Enum.find_index(&step_matches?(expected_step, &1))
    |> mark_consumed(expected_step, missing, remaining)
  end

  defp mark_consumed(nil, expected_step, missing, remaining),
    do: {[expected_step | missing], remaining}

  defp mark_consumed(index, _expected_step, missing, remaining),
    do: {missing, List.delete_at(remaining, index)}

  defp step_matches?(%{name: name} = expected_step, %{name: name, args: args}),
    do: args_subset?(Map.get(expected_step, :args), args)

  defp step_matches?(_expected_step, _actual_step), do: false

  defp args_subset?(nil, _args), do: true

  defp args_subset?(expected_args, args) when is_map(expected_args),
    do: Enum.all?(expected_args, fn {key, value} -> Map.fetch(args, key) == {:ok, value} end)
end
