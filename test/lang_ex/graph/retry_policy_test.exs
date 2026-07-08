defmodule LangEx.Graph.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph.RetryPolicy

  describe "normalize/1" do
    test "nil stays nil and true gets defaults" do
      assert RetryPolicy.normalize(nil) == nil

      assert %{
               max_attempts: 3,
               initial_interval_ms: 100,
               backoff_factor: 2.0,
               max_interval_ms: 30_000,
               jitter: true
             } = RetryPolicy.normalize(true)
    end

    test "backoff_ms is accepted as a legacy alias for initial_interval_ms" do
      assert %{initial_interval_ms: 250} = RetryPolicy.normalize(backoff_ms: 250)
    end

    test "initial_interval_ms wins over the legacy alias" do
      assert %{initial_interval_ms: 50} =
               RetryPolicy.normalize(initial_interval_ms: 50, backoff_ms: 250)
    end
  end

  describe "delay_ms/2" do
    test "grows exponentially without jitter" do
      policy = RetryPolicy.normalize(initial_interval_ms: 100, backoff_factor: 2.0, jitter: false)

      assert RetryPolicy.delay_ms(policy, 1) == 100
      assert RetryPolicy.delay_ms(policy, 2) == 200
      assert RetryPolicy.delay_ms(policy, 3) == 400
      assert RetryPolicy.delay_ms(policy, 4) == 800
    end

    test "is capped by max_interval_ms" do
      policy =
        RetryPolicy.normalize(
          initial_interval_ms: 100,
          backoff_factor: 10.0,
          max_interval_ms: 500,
          jitter: false
        )

      assert RetryPolicy.delay_ms(policy, 1) == 100
      assert RetryPolicy.delay_ms(policy, 2) == 500
      assert RetryPolicy.delay_ms(policy, 10) == 500
    end

    test "jitter adds at most 10% on top of the base delay" do
      policy = RetryPolicy.normalize(initial_interval_ms: 1_000, jitter: true)

      delays = for _ <- 1..50, do: RetryPolicy.delay_ms(policy, 1)

      assert Enum.all?(delays, &(&1 > 1_000 and &1 <= 1_100))
    end
  end
end
