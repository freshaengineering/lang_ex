defmodule LangEx.Store.ETS do
  @moduledoc """
  In-memory `LangEx.Store` backend.

  Values live in a public ETS table owned by the application — fast and
  dependency-free, but per-VM and lost on restart. Use for development,
  tests, and ephemeral memory.

  ## Semantic search

  Configure an embedder to enable similarity search:

      Graph.compile(builder,
        store: {LangEx.Store.ETS, index: [embed: &MyApp.embed/1]}
      )

  The `:embed` function maps a string to a numeric vector (`[number()]`).
  `put/4` embeds each value's text; `search/3` with a `:query` embeds the
  query and returns entries ranked by cosine similarity (highest first).
  Without an embedder, `search/3` falls back to prefix ordering.
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
  def put(config, namespace, key, value) do
    :ets.insert(@table, {{namespace, key}, value, embed_value(config, value)})
    :ok
  end

  @impl true
  def delete(_config, namespace, key) do
    :ets.delete(@table, {namespace, key})
    :ok
  end

  @impl true
  def search(config, namespace, opts \\ []) do
    entries = :ets.match_object(@table, {{namespace, :_}, :_, :_})

    opts
    |> Keyword.get(:query)
    |> run_search(entries, config, opts)
  end

  @doc "Removes every entry (test helper)."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp run_search(nil, entries, _config, opts), do: prefix_search(entries, opts)

  defp run_search(query, entries, config, opts) do
    config
    |> embedder()
    |> semantic_search(query, entries, opts)
  end

  defp prefix_search(entries, opts) do
    prefix = Keyword.get(opts, :prefix, "")
    limit = Keyword.get(opts, :limit, 100)

    entries
    |> Enum.map(fn {{_namespace, key}, value, _vector} -> {key, value} end)
    |> Enum.filter(fn {key, _value} -> String.starts_with?(key, prefix) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(limit)
  end

  defp semantic_search(nil, _query, entries, opts), do: prefix_search(entries, opts)

  defp semantic_search(embed, query, entries, opts) do
    limit = Keyword.get(opts, :limit, 100)
    query_vector = embed.(query)

    entries
    |> Enum.map(fn {{_namespace, key}, value, vector} ->
      {key, value, cosine(query_vector, vector)}
    end)
    |> Enum.reject(fn {_key, _value, score} -> is_nil(score) end)
    |> Enum.sort_by(fn {_key, _value, score} -> score end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {key, value, _score} -> {key, value} end)
  end

  defp embed_value(config, value) do
    config
    |> embedder()
    |> apply_embedder(value)
  end

  defp apply_embedder(nil, _value), do: nil
  defp apply_embedder(embed, value), do: value |> searchable_text() |> embed.()

  defp embedder(config) do
    config
    |> Keyword.get(:index, [])
    |> Keyword.get(:embed)
  end

  defp searchable_text(value) when is_binary(value), do: value
  defp searchable_text(value), do: inspect(value)

  defp cosine(_query_vector, nil), do: nil

  defp cosine(query_vector, vector) when length(query_vector) == length(vector) do
    query_vector
    |> Enum.zip(vector)
    |> Enum.map(fn {x, y} -> x * y end)
    |> Enum.sum()
    |> divide(magnitude(query_vector) * magnitude(vector))
  end

  defp cosine(_query_vector, _vector), do: nil

  defp magnitude(vector), do: vector |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()

  defp divide(_dot, denominator) when denominator == 0.0, do: nil
  defp divide(dot, denominator), do: dot / denominator

  defp wrap_lookup([{_key, value, _vector}]), do: {:ok, value}
  defp wrap_lookup([]), do: :none
end
