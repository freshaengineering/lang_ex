defmodule LangEx.Graph.NodeCache do
  @moduledoc """
  ETS-backed memoization for node results (the `cache:` node option).

  Entries are keyed by `{node_name, input_state_hash}` and carry the
  full input term plus an expiry deadline. The stored input is compared
  on lookup, so a hash collision misses instead of serving a wrong
  result. Expired entries are deleted when read.

  The table is created by the application supervisor and shared across
  all graphs in the VM. Its size is bounded by the `:node_cache_max_entries`
  application env (default #{10_000}): when full, expired entries are
  purged first and, if still full, the whole table is flushed — a coarse
  but predictable eviction that keeps memory bounded.
  """

  @table :lang_ex_node_cache
  @default_max_entries 10_000

  @doc false
  @spec create_table() :: :ok
  def create_table do
    @table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok
  end

  @doc "Looks up a cached, unexpired node result whose input matches exactly."
  @spec fetch(term(), term()) :: {:ok, term()} | :miss
  def fetch(key, input) do
    @table
    |> :ets.lookup(key)
    |> validate_entry(key, input, System.monotonic_time(:millisecond))
  end

  @doc "Stores a node result with the given TTL in milliseconds (or `:infinity`)."
  @spec store(term(), term(), term(), timeout()) :: :ok
  def store(key, input, result, ttl) do
    :ok = ensure_capacity()
    :ets.insert(@table, {key, input, result, deadline(ttl)})
    :ok
  end

  @doc "Removes all cached node results."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp validate_entry([{_key, stored_input, result, :infinity}], _key2, input, _now)
       when stored_input == input,
       do: {:ok, result}

  defp validate_entry([{_key, stored_input, result, expiry}], _key2, input, now)
       when stored_input == input and is_integer(expiry) and now < expiry,
       do: {:ok, result}

  defp validate_entry([{_key, stored_input, _result, expiry}], key, input, now)
       when stored_input == input and is_integer(expiry) and now >= expiry do
    :ets.delete(@table, key)
    :miss
  end

  defp validate_entry(_entries, _key, _input, _now), do: :miss

  defp ensure_capacity do
    @table
    |> :ets.info(:size)
    |> prune_if_full(max_entries())
  end

  defp prune_if_full(size, max) when size < max, do: :ok

  defp prune_if_full(_size, max) do
    purge_expired()

    @table
    |> :ets.info(:size)
    |> flush_if_still_full(max)
  end

  defp flush_if_still_full(size, max) when size < max, do: :ok
  defp flush_if_still_full(_size, _max), do: clear()

  defp purge_expired do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table, [
      {{:_, :_, :_, :"$1"}, [{:andalso, {:is_integer, :"$1"}, {:<, :"$1", now}}], [true]}
    ])

    :ok
  end

  defp max_entries,
    do: Application.get_env(:lang_ex, :node_cache_max_entries, @default_max_entries)

  defp deadline(:infinity), do: :infinity
  defp deadline(ttl) when is_integer(ttl), do: System.monotonic_time(:millisecond) + ttl
end
