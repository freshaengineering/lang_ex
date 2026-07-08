defmodule LangEx.Graph.NodeCache do
  @moduledoc """
  ETS-backed memoization for node results (the `cache:` node option).

  Entries are keyed by `{node_name, input_state_hash}` and carry an
  expiry deadline. The table is created by `LangEx.Application` and
  shared across all graphs in the VM.
  """

  @table :lang_ex_node_cache

  @doc false
  @spec create_table() :: :ok
  def create_table do
    @table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok
  end

  @doc "Looks up a cached, unexpired node result."
  @spec fetch(term()) :: {:ok, term()} | :miss
  def fetch(key) do
    @table
    |> :ets.lookup(key)
    |> unexpired(System.monotonic_time(:millisecond))
  end

  @doc "Stores a node result with the given TTL in milliseconds (or `:infinity`)."
  @spec store(term(), term(), timeout()) :: :ok
  def store(key, result, ttl) do
    :ets.insert(@table, {key, result, deadline(ttl)})
    :ok
  end

  @doc "Removes all cached node results."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp unexpired([{_key, result, :infinity}], _now), do: {:ok, result}
  defp unexpired([{_key, result, deadline}], now) when now < deadline, do: {:ok, result}
  defp unexpired(_entries, _now), do: :miss

  defp deadline(:infinity), do: :infinity
  defp deadline(ttl) when is_integer(ttl), do: System.monotonic_time(:millisecond) + ttl
end
