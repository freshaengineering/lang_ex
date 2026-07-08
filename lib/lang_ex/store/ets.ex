defmodule LangEx.Store.ETS do
  @moduledoc """
  In-memory `LangEx.Store` backend.

  Values live in a public ETS table owned by the application — fast and
  dependency-free, but per-VM and lost on restart. Use for development,
  tests, and ephemeral memory.
  """

  @behaviour LangEx.Store

  @table :lang_ex_store

  @doc false
  @spec create_table() :: :ok
  def create_table do
    @table = :ets.new(@table, [:named_table, :public, :ordered_set, read_concurrency: true])
    :ok
  end

  @impl true
  def get(_config, namespace, key) do
    @table
    |> :ets.lookup({namespace, key})
    |> wrap_lookup()
  end

  @impl true
  def put(_config, namespace, key, value) do
    :ets.insert(@table, {{namespace, key}, value})
    :ok
  end

  @impl true
  def delete(_config, namespace, key) do
    :ets.delete(@table, {namespace, key})
    :ok
  end

  @impl true
  def search(_config, namespace, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "")
    limit = Keyword.get(opts, :limit, 100)

    @table
    |> :ets.match_object({{namespace, :_}, :_})
    |> Enum.map(fn {{_namespace, key}, value} -> {key, value} end)
    |> Enum.filter(fn {key, _value} -> String.starts_with?(key, prefix) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(limit)
  end

  @doc "Removes every entry (test helper)."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp wrap_lookup([{_key, value}]), do: {:ok, value}
  defp wrap_lookup([]), do: :none
end
