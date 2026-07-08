if Code.ensure_loaded?(Ecto) do
  defmodule LangEx.Checkpointer.Postgres do
    @moduledoc """
    PostgreSQL-backed checkpointer using Ecto.

    Assumes the `lang_ex_checkpoints` table has been created via
    `LangEx.Migration`. See `LangEx.Migration` for setup instructions.

    State is encoded with `LangEx.Checkpoint.Serializer`, so structs, atoms,
    and tuples survive the round-trip exactly.

    ## Config

    The `:repo` key must point to an Ecto.Repo module:

        config = [repo: MyApp.Repo, thread_id: "thread-1"]
        LangEx.Checkpointer.Postgres.save(config, checkpoint)
    """

    @behaviour LangEx.Checkpointer

    import Ecto.Query

    alias LangEx.Checkpoint
    alias LangEx.Checkpoint.Serializer
    alias LangEx.Checkpointer.Postgres.Schema

    @impl true
    def save(config, %Checkpoint{} = cp) do
      repo = Keyword.fetch!(config, :repo)

      attrs = %{
        thread_id: cp.thread_id,
        checkpoint_id: cp.checkpoint_id,
        parent_id: cp.parent_id,
        state: Serializer.encode(cp.state),
        next_nodes: Enum.map(cp.next_nodes, &Serializer.encode/1),
        step: cp.step,
        metadata: Serializer.encode(cp.metadata || %{}),
        pending_interrupts: encode_interrupts(cp.pending_interrupts),
        created_at: cp.created_at,
        version: cp.version
      }

      %Schema{}
      |> Ecto.Changeset.cast(attrs, Map.keys(attrs))
      |> repo.insert(
        on_conflict:
          {:replace,
           [:parent_id, :state, :next_nodes, :step, :metadata, :pending_interrupts, :version]},
        conflict_target: [:thread_id, :checkpoint_id]
      )
      |> handle_insert()
    end

    @impl true
    def load(config) do
      repo = Keyword.fetch!(config, :repo)
      thread_id = Keyword.fetch!(config, :thread_id)

      Schema
      |> where([c], c.thread_id == ^thread_id)
      |> scope_checkpoint_id(Keyword.get(config, :checkpoint_id))
      |> order_by([c], desc: c.created_at, desc: c.step, desc: c.checkpoint_id)
      |> limit(1)
      |> repo.one()
      |> to_checkpoint()
    end

    @impl true
    def list(config, opts \\ []) do
      repo = Keyword.fetch!(config, :repo)
      thread_id = Keyword.fetch!(config, :thread_id)
      row_limit = Keyword.get(opts, :limit, 100)

      Schema
      |> where([c], c.thread_id == ^thread_id)
      |> order_by([c], desc: c.created_at, desc: c.step, desc: c.checkpoint_id)
      |> limit(^row_limit)
      |> repo.all()
      |> Enum.map(&schema_to_checkpoint/1)
    end

    @impl true
    def delete_thread(config) do
      repo = Keyword.fetch!(config, :repo)
      thread_id = Keyword.fetch!(config, :thread_id)

      Schema
      |> where([c], c.thread_id == ^thread_id)
      |> repo.delete_all()

      :ok
    end

    @doc """
    Deletes checkpoints created before the given `DateTime`, across all
    threads. Returns `{:ok, deleted_count}`. Run periodically (e.g. from
    a scheduled job) to enforce a retention window:

        LangEx.Checkpointer.Postgres.prune([repo: MyApp.Repo],
          older_than: DateTime.add(DateTime.utc_now(), -30, :day)
        )
    """
    @spec prune(keyword(), keyword()) :: {:ok, non_neg_integer()}
    def prune(config, opts) do
      repo = Keyword.fetch!(config, :repo)
      older_than = Keyword.fetch!(opts, :older_than)

      {count, _} =
        Schema
        |> where([c], c.created_at < ^older_than)
        |> repo.delete_all()

      {:ok, count}
    end

    defp scope_checkpoint_id(query, nil), do: query

    defp scope_checkpoint_id(query, checkpoint_id),
      do: where(query, [c], c.checkpoint_id == ^checkpoint_id)

    defp handle_insert({:ok, _row}), do: :ok
    defp handle_insert({:error, changeset}), do: {:error, changeset}

    defp to_checkpoint(nil), do: :none
    defp to_checkpoint(%Schema{} = row), do: {:ok, schema_to_checkpoint(row)}

    defp schema_to_checkpoint(%Schema{} = row) do
      %Checkpoint{
        thread_id: row.thread_id,
        checkpoint_id: row.checkpoint_id,
        parent_id: row.parent_id,
        state: Serializer.decode(row.state),
        next_nodes: Enum.map(row.next_nodes || [], &decode_entry/1),
        step: row.step,
        metadata: Serializer.decode(row.metadata || %{}),
        pending_interrupts: decode_interrupts(row.pending_interrupts),
        created_at: row.created_at,
        version: row.version || 1
      }
    end

    # Format v1 rows stored bare node-name strings; v2 stores
    # Serializer-encoded entries (node atoms or Send structs).
    defp decode_entry(name) when is_binary(name), do: String.to_existing_atom(name)
    defp decode_entry(encoded), do: Serializer.decode(encoded)

    defp encode_interrupts(nil), do: nil

    defp encode_interrupts(list) when is_list(list),
      do: Enum.map(list, &Serializer.encode/1)

    defp decode_interrupts(nil), do: nil

    defp decode_interrupts(list) when is_list(list),
      do: Enum.map(list, &Serializer.decode/1)
  end
end
