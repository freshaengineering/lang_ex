if Code.ensure_loaded?(Ecto) do
  defmodule LangEx.Checkpointer.Postgres do
    @moduledoc """
    PostgreSQL-backed checkpointer using Ecto.

    Assumes the `lang_ex_checkpoints` table has been created via
    `LangEx.Migration`. See `LangEx.Migration` for setup instructions.

    State is encoded with `LangEx.Checkpoint.Serializer`, so structs, atoms,
    and tuples survive the round-trip exactly.

    Large state values (above `:blob_threshold` bytes, default 16KB) are
    stored once per `(thread_id, content_hash)` in `lang_ex_checkpoint_blobs`
    and referenced from the checkpoint row — a value that never changes
    between super-steps (e.g. a big tool catalog) is written once per thread
    instead of into every checkpoint. Requires migration V3. Set
    `blob_threshold: :infinity` in the config to store everything inline.

    Subgraph checkpoints share their parent's `thread_id` and are separated
    by `checkpoint_ns`, so `delete_thread/1` removes an entire run tree and
    blob storage is shared across a thread's namespaces. Requires migration
    V4, which also creates the write journal table backing per-task
    durability.

    ## Config

    The `:repo` key must point to an Ecto.Repo module:

        config = [repo: MyApp.Repo, thread_id: "thread-1"]
        LangEx.Checkpointer.Postgres.save(config, checkpoint)
    """

    @behaviour LangEx.Checkpointer

    import Ecto.Query

    alias LangEx.Checkpoint
    alias LangEx.Checkpoint.Codec
    alias LangEx.Checkpointer
    alias LangEx.Checkpointer.Postgres.BlobSchema
    alias LangEx.Checkpointer.Postgres.Blobs
    alias LangEx.Checkpointer.Postgres.Schema
    alias LangEx.Checkpointer.Postgres.WriteSchema

    @default_blob_threshold 16_384

    @replaceable [
      :parent_id,
      :state,
      :next_nodes,
      :step,
      :metadata,
      :pending_interrupts,
      :source,
      :version
    ]

    @impl true
    def save(config, %Checkpoint{} = cp) do
      repo = Keyword.fetch!(config, :repo)

      {slim_state, blobs} =
        cp.state
        |> Codec.encode(config)
        |> Blobs.split(Keyword.get(config, :blob_threshold, @default_blob_threshold))

      insert_blobs(repo, cp.thread_id, blobs)

      attrs = %{
        thread_id: cp.thread_id,
        checkpoint_ns: cp.checkpoint_ns || "",
        checkpoint_id: cp.checkpoint_id,
        parent_id: cp.parent_id,
        state: slim_state,
        next_nodes: Enum.map(cp.next_nodes || [], &Codec.encode(&1, config)),
        step: cp.step,
        metadata: Codec.encode(cp.metadata || %{}, config),
        pending_interrupts: encode_interrupts(cp.pending_interrupts, config),
        source: to_string(cp.source || :step),
        created_at: cp.created_at,
        version: cp.version
      }

      %Schema{}
      |> Ecto.Changeset.cast(attrs, Map.keys(attrs))
      |> repo.insert(
        on_conflict: {:replace, @replaceable},
        conflict_target: [:thread_id, :checkpoint_ns, :checkpoint_id]
      )
      |> handle_insert()
    end

    @impl true
    def load(config) do
      repo = Keyword.fetch!(config, :repo)

      config
      |> namespace_scope()
      |> scope_checkpoint_id(Keyword.get(config, :checkpoint_id))
      |> newest_first()
      |> limit(1)
      |> repo.one()
      |> to_checkpoint(repo, config)
    end

    @impl true
    def list(config, opts \\ []) do
      repo = Keyword.fetch!(config, :repo)

      config
      |> namespace_scope()
      |> scope_source(Keyword.get(opts, :source))
      |> scope_before(Keyword.get(opts, :before), config, repo)
      |> newest_first()
      |> limit(^Keyword.get(opts, :limit, 100))
      |> repo.all()
      |> Enum.map(&schema_to_checkpoint(&1, repo, config))
    end

    @impl true
    def delete_thread(config) do
      repo = Keyword.fetch!(config, :repo)
      thread_id = Keyword.fetch!(config, :thread_id)

      Enum.each([Schema, WriteSchema, BlobSchema], fn schema ->
        schema
        |> where([r], r.thread_id == ^thread_id)
        |> repo.delete_all()
      end)

      :ok
    end

    @impl true
    def copy_thread(config, target_thread_id) do
      repo = Keyword.fetch!(config, :repo)
      thread_id = Keyword.fetch!(config, :thread_id)

      repo.transaction(fn ->
        copy_rows(repo, "lang_ex_checkpoints", checkpoint_columns(), thread_id, target_thread_id)
        copy_rows(repo, "lang_ex_checkpoint_blobs", blob_columns(), thread_id, target_thread_id)
      end)

      :ok
    end

    @impl true
    def put_writes(config, anchor, write, _opts \\ []) do
      repo = Keyword.fetch!(config, :repo)

      row = %{
        thread_id: Keyword.fetch!(config, :thread_id),
        checkpoint_ns: Checkpointer.namespace(config),
        anchor: anchor,
        task_id: write.task_id,
        idx: write.idx,
        node: to_string(write.node),
        update: %{"v" => Codec.encode(write.update, config)},
        inserted_at: DateTime.utc_now()
      }

      repo.insert_all(WriteSchema, [row],
        on_conflict: {:replace, [:node, :update, :inserted_at]},
        conflict_target: [:thread_id, :checkpoint_ns, :anchor, :task_id, :idx]
      )

      :ok
    end

    @impl true
    def load_writes(config, anchor) do
      repo = Keyword.fetch!(config, :repo)

      config
      |> writes_scope(anchor)
      |> order_by([w], asc: w.inserted_at, asc: w.task_id)
      |> repo.all()
      |> Enum.map(&to_write(&1, config))
    end

    @impl true
    def discard_writes(config, anchor) do
      repo = Keyword.fetch!(config, :repo)

      config
      |> writes_scope(anchor)
      |> repo.delete_all()

      :ok
    end

    @doc """
    Deletes checkpoints created before the given `DateTime`. Returns
    `{:ok, deleted_count}`. Run periodically (e.g. from a scheduled job)
    to enforce a retention window:

        LangEx.Checkpointer.Postgres.prune([repo: MyApp.Repo],
          older_than: DateTime.add(DateTime.utc_now(), -30, :day)
        )

    Scoped to one thread when the config carries a `:thread_id`, across
    all threads otherwise. `:keep_latest` retains that many most recent
    checkpoints per thread regardless of age, so trimming history never
    leaves a live conversation unresumable:

        LangEx.Checkpointer.Postgres.prune([repo: MyApp.Repo, thread_id: "t-1"],
          older_than: cutoff,
          keep_latest: 5
        )
    """
    @spec prune(keyword(), keyword()) :: {:ok, non_neg_integer()}
    def prune(config, opts) do
      repo = Keyword.fetch!(config, :repo)
      older_than = Keyword.fetch!(opts, :older_than)

      {count, _} =
        Schema
        |> where([c], c.created_at < ^older_than)
        |> scope_thread(Keyword.get(config, :thread_id))
        |> exclude_latest(Keyword.get(opts, :keep_latest, 0), config, repo)
        |> repo.delete_all()

      drop_orphaned_blobs(repo)

      {:ok, count}
    end

    defp checkpoint_columns do
      ~w(checkpoint_ns checkpoint_id parent_id state next_nodes step metadata
         pending_interrupts source created_at version)
    end

    defp blob_columns, do: ~w(hash value inserted_at)

    # Rows are copied inside the database, so branching a long thread with
    # large state does not pull its full history through the application.
    defp copy_rows(repo, table, columns, thread_id, target_thread_id) do
      selected = Enum.join(columns, ", ")

      repo.query!(
        """
        INSERT INTO #{table} (thread_id, #{selected})
        SELECT $1, #{selected} FROM #{table} WHERE thread_id = $2
        ON CONFLICT DO NOTHING
        """,
        [target_thread_id, thread_id]
      )
    end

    defp namespace_scope(config) do
      thread_id = Keyword.fetch!(config, :thread_id)
      ns = Checkpointer.namespace(config)

      Schema
      |> where([c], c.thread_id == ^thread_id)
      |> where([c], c.checkpoint_ns == ^ns)
    end

    defp writes_scope(config, anchor) do
      thread_id = Keyword.fetch!(config, :thread_id)
      ns = Checkpointer.namespace(config)

      WriteSchema
      |> where([w], w.thread_id == ^thread_id)
      |> where([w], w.checkpoint_ns == ^ns)
      |> where([w], w.anchor == ^anchor)
    end

    defp newest_first(query),
      do: order_by(query, [c], desc: c.created_at, desc: c.step, desc: c.checkpoint_id)

    defp scope_thread(query, nil), do: query
    defp scope_thread(query, thread_id), do: where(query, [c], c.thread_id == ^thread_id)

    defp scope_checkpoint_id(query, nil), do: query

    defp scope_checkpoint_id(query, checkpoint_id),
      do: where(query, [c], c.checkpoint_id == ^checkpoint_id)

    defp scope_source(query, nil), do: query

    defp scope_source(query, sources) do
      values = sources |> List.wrap() |> Enum.map(&to_string/1)
      where(query, [c], c.source in ^values)
    end

    # Keyset pagination: the cursor's own ordering tuple bounds the page,
    # so paging a long history stays index-friendly at any depth.
    defp scope_before(query, nil, _config, _repo), do: query

    defp scope_before(query, before_id, config, repo) do
      config
      |> namespace_scope()
      |> where([c], c.checkpoint_id == ^before_id)
      |> select([c], {c.created_at, c.step, c.checkpoint_id})
      |> repo.one()
      |> apply_cursor(query, before_id)
    end

    defp apply_cursor(nil, _query, before_id) do
      raise ArgumentError,
            "list/2 received :before #{inspect(before_id)}, which is not a checkpoint " <>
              "of this thread and namespace"
    end

    defp apply_cursor({created_at, step, checkpoint_id}, query, _before_id) do
      where(
        query,
        [c],
        {c.created_at, c.step, c.checkpoint_id} < {^created_at, ^step, ^checkpoint_id}
      )
    end

    defp exclude_latest(query, 0, _config, _repo), do: query

    defp exclude_latest(query, keep, config, repo) do
      kept =
        Schema
        |> scope_thread(Keyword.get(config, :thread_id))
        |> newest_first()
        |> limit(^keep)
        |> select([c], c.checkpoint_id)
        |> repo.all()

      where(query, [c], c.checkpoint_id not in ^kept)
    end

    defp drop_orphaned_blobs(repo) do
      live_threads = from(c in Schema, where: c.thread_id == parent_as(:blob).thread_id)

      from(b in BlobSchema, as: :blob, where: not exists(live_threads))
      |> repo.delete_all()
    end

    defp handle_insert({:ok, _row}), do: :ok
    defp handle_insert({:error, changeset}), do: {:error, changeset}

    defp insert_blobs(_repo, _thread_id, blobs) when blobs == %{}, do: :ok

    defp insert_blobs(repo, thread_id, blobs) do
      rows =
        Enum.map(blobs, fn {hash, value} ->
          %{thread_id: thread_id, hash: hash, value: %{"v" => value}}
        end)

      repo.insert_all(BlobSchema, rows,
        on_conflict: :nothing,
        conflict_target: [:thread_id, :hash]
      )

      :ok
    end

    defp fetch_blobs(_repo, _thread_id, []), do: %{}

    defp fetch_blobs(repo, thread_id, hashes) do
      BlobSchema
      |> where([b], b.thread_id == ^thread_id)
      |> where([b], b.hash in ^hashes)
      |> select([b], {b.hash, b.value})
      |> repo.all()
      |> Map.new(fn {hash, %{"v" => value}} -> {hash, value} end)
    end

    defp resolve_state(encoded, repo, thread_id),
      do: Blobs.resolve(encoded, &fetch_blobs(repo, thread_id, &1))

    defp to_checkpoint(nil, _repo, _config), do: :none

    defp to_checkpoint(%Schema{} = row, repo, config),
      do: {:ok, schema_to_checkpoint(row, repo, config)}

    defp schema_to_checkpoint(%Schema{} = row, repo, config) do
      %Checkpoint{
        thread_id: row.thread_id,
        checkpoint_ns: row.checkpoint_ns || "",
        checkpoint_id: row.checkpoint_id,
        parent_id: row.parent_id,
        state: row.state |> resolve_state(repo, row.thread_id) |> Codec.decode(config),
        next_nodes: Enum.map(row.next_nodes || [], &decode_entry(&1, config)),
        step: row.step,
        metadata: Codec.decode(row.metadata || %{}, config),
        pending_interrupts: decode_interrupts(row.pending_interrupts, config),
        source: decode_source(row.source),
        created_at: row.created_at,
        version: row.version || 1
      }
    end

    defp to_write(%WriteSchema{} = row, config) do
      %{
        task_id: row.task_id,
        node: String.to_existing_atom(row.node),
        update: row.update |> Map.fetch!("v") |> Codec.decode(config),
        idx: row.idx
      }
    end

    # Rows written before V4 default to :step, the only provenance the
    # engine had at the time.
    defp decode_source(nil), do: :step
    defp decode_source(source), do: String.to_existing_atom(source)

    # Format v1 rows stored bare node-name strings; v2 stores
    # Serializer-encoded entries (node atoms or Send structs).
    defp decode_entry(name, _config) when is_binary(name), do: String.to_existing_atom(name)
    defp decode_entry(encoded, config), do: Codec.decode(encoded, config)

    defp encode_interrupts(nil, _config), do: nil

    defp encode_interrupts(list, config) when is_list(list),
      do: Enum.map(list, &Codec.encode(&1, config))

    defp decode_interrupts(nil, _config), do: nil

    defp decode_interrupts(list, config) when is_list(list),
      do: Enum.map(list, &Codec.decode(&1, config))
  end
end
