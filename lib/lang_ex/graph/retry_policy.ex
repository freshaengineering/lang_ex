defmodule LangEx.Graph.RetryPolicy do
  @moduledoc """
  Retry configuration for the `retry:` node option.

  Attempts retry on exceptions only — `{:error, term}` return values are
  ordinary node results and are never retried. Delays grow exponentially
  and are capped:

      delay = min(max_interval_ms, initial_interval_ms * backoff_factor^(attempt - 1))

  With `jitter: true` (the default) up to 10% random delay is added so
  simultaneous retries do not stampede a recovering dependency.

  ## Options

    * `:max_attempts` — total attempts including the first (default 3)
    * `:initial_interval_ms` — delay before the first retry (default 100);
      `:backoff_ms` is accepted as a legacy alias
    * `:backoff_factor` — exponential growth factor (default 2.0)
    * `:max_interval_ms` — delay ceiling (default 30_000)
    * `:jitter` — add up to 10% random delay (default `true`)
    * `:retryable?` — `(exception -> boolean)` filter (default: retry all)
  """

  @type t :: %{
          max_attempts: pos_integer(),
          initial_interval_ms: non_neg_integer(),
          backoff_factor: number(),
          max_interval_ms: pos_integer(),
          jitter: boolean(),
          retryable?: (Exception.t() -> boolean())
        }

  @doc "Normalizes the `retry:` node option into a policy map."
  @spec normalize(nil | true | keyword()) :: t() | nil
  def normalize(nil), do: nil

  def normalize(true), do: normalize([])

  def normalize(retry_opts) when is_list(retry_opts) do
    %{
      max_attempts: Keyword.get(retry_opts, :max_attempts, 3),
      initial_interval_ms:
        Keyword.get(retry_opts, :initial_interval_ms, Keyword.get(retry_opts, :backoff_ms, 100)),
      backoff_factor: Keyword.get(retry_opts, :backoff_factor, 2.0),
      max_interval_ms: Keyword.get(retry_opts, :max_interval_ms, 30_000),
      jitter: Keyword.get(retry_opts, :jitter, true),
      retryable?: Keyword.get(retry_opts, :retryable?, fn _exception -> true end)
    }
  end

  @doc "Delay in milliseconds before retrying after the given failed attempt."
  @spec delay_ms(t(), pos_integer()) :: non_neg_integer()
  def delay_ms(policy, attempt) when attempt >= 1 do
    policy.max_interval_ms
    |> min(policy.initial_interval_ms * :math.pow(policy.backoff_factor, attempt - 1))
    |> trunc()
    |> add_jitter(policy.jitter)
  end

  defp add_jitter(interval, false), do: interval
  defp add_jitter(interval, true), do: interval + :rand.uniform(max(1, div(interval, 10)))
end
