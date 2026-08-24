defmodule LangEx.Middleware.CallBudget do
  @moduledoc """
  Middleware that caps what one agent run is allowed to spend.

  An agent that can call itself in a loop can also loop forever: a tool that
  keeps failing, two tools that undo each other, a model that will not commit
  to an answer. A budget turns that from an unbounded bill into a bounded run
  that stops and says why.

  When a budget is spent the run ends after the current model call. Any tool
  calls the model just requested are answered as errors rather than left
  hanging, so the conversation stays valid and can be continued later — a
  request with an unanswered tool call is rejected by providers.

  `:budget_exhausted` is set on the state so a caller can tell a run that was
  cut short from one the model finished on its own.

  ## Options

  - `:max_model_calls` — most model calls one run may make. Default `nil`
    (uncapped).
  - `:max_tokens` — most tokens (input plus output, as reported in
    `:llm_usage`) one run may consume. Default `nil` (uncapped).
  - `:messages_key` — state key holding the conversation (default
    `:messages`).

  Budgets count per run, not per thread: a resumed or continued conversation
  starts a fresh allowance, since the caller chose to spend more.

  ## Example

      LangEx.Prebuilt.agent(
        model: "claude-sonnet-5",
        tools: tools,
        middleware: [CallBudget.new(max_model_calls: 8, max_tokens: 150_000)]
      )
  """

  alias LangEx.Message
  alias LangEx.Middleware
  alias LangEx.Tool

  @calls_key :model_calls
  @exhausted_key :budget_exhausted

  @doc "Builds a call-budget middleware. See the module doc for options."
  @spec new(keyword()) :: Middleware.t()
  def new(opts \\ []) do
    Middleware.new(
      name: :call_budget,
      state_schema: [{@calls_key, 0}, {@exhausted_key, false}],
      before_model: &count_call/1,
      after_model: enforcer(opts)
    )
  end

  @doc "The state key holding how many model calls this run has made."
  @spec calls_key() :: atom()
  def calls_key, do: @calls_key

  @doc "The state key set when a run was stopped by its budget."
  @spec exhausted_key() :: atom()
  def exhausted_key, do: @exhausted_key

  defp count_call(state), do: %{@calls_key => Map.get(state, @calls_key, 0) + 1}

  defp enforcer(opts) do
    limits = %{
      calls: Keyword.get(opts, :max_model_calls),
      tokens: Keyword.get(opts, :max_tokens)
    }

    messages_key = Keyword.get(opts, :messages_key, :messages)

    fn state -> state |> overspend(limits) |> stop(state, messages_key) end
  end

  # The first breached limit explains the stop; checking calls first keeps the
  # message stable when a run trips both at once.
  defp overspend(state, limits) do
    [calls_over(state, limits.calls), tokens_over(state, limits.tokens)]
    |> Enum.find(& &1)
  end

  defp calls_over(_state, nil), do: nil

  defp calls_over(state, max) do
    state
    |> Map.get(@calls_key, 0)
    |> breach("model call budget", max)
  end

  defp tokens_over(_state, nil), do: nil

  defp tokens_over(state, max) do
    state
    |> Map.get(:llm_usage, %{})
    |> total_tokens()
    |> breach("token budget", max)
  end

  defp breach(spent, _label, max) when spent < max, do: nil
  defp breach(spent, label, max), do: "#{label} of #{max} reached (#{spent} used)"

  defp total_tokens(usage),
    do: Map.get(usage, :input_tokens, 0) + Map.get(usage, :output_tokens, 0)

  defp stop(nil, _state, _messages_key), do: %{}

  defp stop(reason, state, messages_key) do
    state
    |> Map.get(messages_key, [])
    |> Tool.Node.pending_calls()
    |> Enum.map(&Message.tool_error("Stopped: #{reason}.", &1.id))
    |> then(
      &%{
        messages_key => &1,
        @exhausted_key => true,
        Middleware.jump_key() => :__end__
      }
    )
  end
end
