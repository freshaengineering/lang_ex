if Code.ensure_loaded?(Ecto) do
  defmodule LangEx.Store.Postgres do
    @moduledoc """
    PostgreSQL-backed `LangEx.Store` using Ecto.

    Assumes the `lang_ex_store` table has been created via
    `LangEx.Migration` (version 2). Values are encoded with
    `LangEx.Checkpoint.Serializer`, so structs, atoms, and tuples
    round-trip exactly.

    ## Config

        Graph.compile(builder, store: {LangEx.Store.Postgres, repo: MyApp.Repo})
    """

    @behaviour LangEx.Store

    import Ecto.Query

    alias LangEx.Checkpoint.Serializer
    alias LangEx.Store.Postgres.Schema

    @impl true
    def get(config, namespace, key) do
      repo = Keyword.fetch!(config, :repo)

      Schema
      |> where([s], s.namespace == ^namespace)
      |> where([s], s.key == ^key)
      |> repo.one()
      |> wrap_row()
    end

    @impl true
    def put(config, namespace, key, value) do
      repo = Keyword.fetch!(config, :repo)
      now = DateTime.utc_now()

      %Schema{}
      |> Ecto.Changeset.change(
        namespace: namespace,
        key: key,
        value: %{"data" => Serializer.encode(value)},
        inserted_at: now,
        updated_at: now
      )
      |> repo.insert(
        on_conflict: {:replace, [:value, :updated_at]},
        conflict_target: [:namespace, :key]
      )
      |> wrap_write()
    end

    @impl true
    def delete(config, namespace, key) do
      repo = Keyword.fetch!(config, :repo)

      Schema
      |> where([s], s.namespace == ^namespace)
      |> where([s], s.key == ^key)
      |> repo.delete_all()

      :ok
    end

    @impl true
    def search(config, namespace, opts \\ []) do
      repo = Keyword.fetch!(config, :repo)
      prefix = Keyword.get(opts, :prefix, "")
      limit = Keyword.get(opts, :limit, 100)

      Schema
      |> where([s], s.namespace == ^namespace)
      |> where([s], like(s.key, ^"#{escape_like(prefix)}%"))
      |> order_by([s], asc: s.key)
      |> limit(^limit)
      |> select([s], {s.key, s.value})
      |> repo.all()
      |> Enum.map(fn {key, value} -> {key, decode_value(value)} end)
    end

    defp wrap_row(nil), do: :none
    defp wrap_row(%Schema{value: value}), do: {:ok, decode_value(value)}

    defp wrap_write({:ok, _row}), do: :ok
    defp wrap_write({:error, changeset}), do: {:error, changeset}

    defp decode_value(%{"data" => encoded}), do: Serializer.decode(encoded)

    defp escape_like(prefix) do
      String.replace(prefix, ["\\", "%", "_"], &"\\#{&1}")
    end
  end
end
