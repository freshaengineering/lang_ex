if Code.ensure_loaded?(Redix) do
  defmodule LangEx.Checkpointer.Redis do
    @moduledoc """
    Redis-backed checkpointer using Redix.

    Checkpoints are stored as JSON under
    `lang_ex:cp:{thread_id}:{checkpoint_ns}:{checkpoint_id}`. A sorted set
    `lang_ex:idx:{thread_id}:{checkpoint_ns}` indexes checkpoint IDs by
    timestamp for ordered retrieval, and a set
    `lang_ex:ns:{thread_id}` tracks which namespaces a thread has written
    so `delete_thread/1` and `copy_thread/2` can span the whole run tree
    without scanning the keyspace.

    State is encoded with `LangEx.Checkpoint.Serializer`, so structs, atoms,
    and tuples survive the round-trip exactly.

    Ordering uses the checkpoint's `created_at` with microsecond
    precision as the sorted-set score; checkpoints created in the same
    microsecond (only possible with `durability: :async` bursts) order
    lexicographically by checkpoint ID. Use the `parent_id` chain when
    exact lineage matters.
    """

    @behaviour LangEx.Checkpointer

    alias LangEx.Checkpoint
    alias LangEx.Checkpoint.Codec
    alias LangEx.Checkpointer

    @prefix "lang_ex"
    @default_conn LangEx.Redix

    @impl true
    def save(config, %Checkpoint{} = cp) do
      conn = conn(config)
      thread_id = Keyword.fetch!(config, :thread_id)
      ns = cp.checkpoint_ns || ""
      key = checkpoint_key(thread_id, ns, cp.checkpoint_id)
      index_key = index_key(thread_id, ns)
      score = DateTime.to_unix(cp.created_at, :microsecond)

      with {:ok, _} <- Redix.command(conn, ["SET", key, serialize(cp, config)]),
           {:ok, _} <- Redix.command(conn, ["ZADD", index_key, score, cp.checkpoint_id]),
           {:ok, _} <- Redix.command(conn, ["SADD", ns_key(thread_id), ns]) do
        apply_ttl(conn, config, [key, index_key, ns_key(thread_id)])
        :ok
      end
    end

    @impl true
    def load(config) do
      config
      |> Keyword.get(:checkpoint_id)
      |> load_by_id(config)
    end

    @impl true
    def list(config, opts \\ []) do
      conn = conn(config)
      thread_id = Keyword.fetch!(config, :thread_id)
      ns = Checkpointer.namespace(config)

      with {:ok, ids} <- Redix.command(conn, ["ZREVRANGE", index_key(thread_id, ns), "0", "-1"]),
           {:ok, values} <- fetch_values(conn, thread_id, ns, ids) do
        values
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&deserialize(&1, config))
        |> filter_source(Keyword.get(opts, :source))
        |> drop_until_after(Keyword.get(opts, :before))
        |> Enum.take(Keyword.get(opts, :limit, 100))
      end
    end

    @impl true
    def delete_thread(config) do
      conn = conn(config)
      thread_id = Keyword.fetch!(config, :thread_id)

      with {:ok, namespaces} <- Redix.command(conn, ["SMEMBERS", ns_key(thread_id)]),
           keys = Enum.flat_map(namespaces, &namespace_keys(conn, thread_id, &1)),
           {:ok, _} <- Redix.command(conn, ["DEL", ns_key(thread_id) | keys]) do
        :ok
      end
    end

    @impl true
    def copy_thread(config, target_thread_id) do
      conn = conn(config)
      thread_id = Keyword.fetch!(config, :thread_id)

      with {:ok, namespaces} <- Redix.command(conn, ["SMEMBERS", ns_key(thread_id)]) do
        Enum.each(namespaces, &copy_namespace(conn, config, thread_id, target_thread_id, &1))
        :ok
      end
    end

    @impl true
    def put_writes(config, anchor, write, _opts \\ []) do
      conn = conn(config)
      key = writes_key(config, anchor)

      with {:ok, _} <-
             Redix.command(conn, [
               "HSET",
               key,
               "#{write.task_id}:#{write.idx}",
               Jason.encode!(Codec.encode(write, config))
             ]) do
        apply_ttl(conn, config, [key])
        :ok
      end
    end

    @impl true
    def load_writes(config, anchor) do
      config
      |> conn()
      |> Redix.command(["HGETALL", writes_key(config, anchor)])
      |> decode_writes(config)
    end

    @impl true
    def discard_writes(config, anchor) do
      with {:ok, _} <- Redix.command(conn(config), ["DEL", writes_key(config, anchor)]) do
        :ok
      end
    end

    defp copy_namespace(conn, config, thread_id, target_thread_id, ns) do
      with {:ok, ids} <- Redix.command(conn, ["ZREVRANGE", index_key(thread_id, ns), "0", "-1"]),
           {:ok, values} <- fetch_values(conn, thread_id, ns, ids) do
        values
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&deserialize(&1, config))
        |> Enum.each(&save(rebind(config, target_thread_id), %{&1 | thread_id: target_thread_id}))
      end
    end

    defp rebind(config, thread_id), do: Keyword.put(config, :thread_id, thread_id)

    defp namespace_keys(conn, thread_id, ns) do
      {:ok, ids} = Redix.command(conn, ["ZRANGE", index_key(thread_id, ns), "0", "-1"])
      [index_key(thread_id, ns) | Enum.map(ids, &checkpoint_key(thread_id, ns, &1))]
    end

    defp fetch_values(_conn, _thread_id, _ns, []), do: {:ok, []}

    defp fetch_values(conn, thread_id, ns, ids) do
      Redix.command(conn, ["MGET" | Enum.map(ids, &checkpoint_key(thread_id, ns, &1))])
    end

    defp load_by_id(nil, config) do
      conn = conn(config)
      thread_id = Keyword.fetch!(config, :thread_id)
      ns = Checkpointer.namespace(config)

      with {:ok, [latest_id]} <-
             Redix.command(conn, ["ZREVRANGE", index_key(thread_id, ns), "0", "0"]) do
        fetch_checkpoint(conn, thread_id, ns, latest_id, config)
      else
        {:ok, []} -> :none
        {:error, _} = err -> err
      end
    end

    defp load_by_id(checkpoint_id, config) do
      fetch_checkpoint(
        conn(config),
        Keyword.fetch!(config, :thread_id),
        Checkpointer.namespace(config),
        checkpoint_id,
        config
      )
    end

    defp fetch_checkpoint(conn, thread_id, ns, checkpoint_id, config) do
      conn
      |> Redix.command(["GET", checkpoint_key(thread_id, ns, checkpoint_id)])
      |> handle_fetch(config)
    end

    defp handle_fetch({:ok, nil}, _config), do: :none
    defp handle_fetch({:ok, data}, config), do: {:ok, deserialize(data, config)}
    defp handle_fetch({:error, _} = err, _config), do: err

    defp filter_source(checkpoints, nil), do: checkpoints

    defp filter_source(checkpoints, sources) do
      allowed = MapSet.new(List.wrap(sources))
      Enum.filter(checkpoints, &MapSet.member?(allowed, &1.source))
    end

    defp drop_until_after(checkpoints, nil), do: checkpoints

    defp drop_until_after(checkpoints, before_id) do
      checkpoints
      |> Enum.drop_while(&(&1.checkpoint_id != before_id))
      |> exclude_cursor(before_id)
    end

    defp exclude_cursor([], before_id) do
      raise ArgumentError,
            "list/2 received :before #{inspect(before_id)}, which is not a checkpoint " <>
              "of this thread and namespace"
    end

    defp exclude_cursor([_cursor | older], _before_id), do: older

    defp decode_writes({:ok, flat}, config) do
      flat
      |> Enum.chunk_every(2)
      |> Enum.map(fn [field, json] ->
        {field, json |> Jason.decode!() |> Codec.decode(config)}
      end)
      |> Enum.sort_by(fn {field, _write} -> field end)
      |> Enum.map(fn {_field, write} -> write end)
    end

    defp decode_writes({:error, _}, _config), do: []

    defp conn(config), do: config[:conn] || @default_conn

    defp checkpoint_key(thread_id, ns, cp_id), do: "#{@prefix}:cp:#{thread_id}:#{ns}:#{cp_id}"
    defp index_key(thread_id, ns), do: "#{@prefix}:idx:#{thread_id}:#{ns}"
    defp ns_key(thread_id), do: "#{@prefix}:ns:#{thread_id}"

    defp writes_key(config, anchor) do
      thread_id = Keyword.fetch!(config, :thread_id)
      "#{@prefix}:w:#{thread_id}:#{Checkpointer.namespace(config)}:#{anchor}"
    end

    defp apply_ttl(conn, config, keys) do
      config
      |> Keyword.get(:ttl)
      |> set_expiry(conn, keys)
    end

    defp set_expiry(nil, _conn, _keys), do: :ok

    defp set_expiry(ttl, conn, keys) do
      Enum.each(keys, &Redix.command(conn, ["EXPIRE", &1, "#{ttl}"]))
      :ok
    end

    defp serialize(%Checkpoint{} = cp, config) do
      cp
      |> Codec.encode(config)
      |> Jason.encode!()
    end

    defp deserialize(json, config) do
      json
      |> Jason.decode!()
      |> Codec.decode(config)
    end
  end
end
