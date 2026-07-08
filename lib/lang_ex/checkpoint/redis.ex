if Code.ensure_loaded?(Redix) do
  defmodule LangEx.Checkpointer.Redis do
    @moduledoc """
    Redis-backed checkpointer using Redix.

    Checkpoints are stored as JSON under `lang_ex:cp:{thread_id}:{checkpoint_id}`.
    A sorted set `lang_ex:thread:{thread_id}` indexes checkpoint IDs by timestamp
    for ordered retrieval.

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
    alias LangEx.Checkpoint.Serializer

    @prefix "lang_ex"
    @default_conn LangEx.Redix

    @impl true
    def save(config, %Checkpoint{} = cp) do
      conn = config[:conn] || @default_conn
      thread_id = Keyword.fetch!(config, :thread_id)
      key = checkpoint_key(thread_id, cp.checkpoint_id)
      index_key = thread_index_key(thread_id)
      score = DateTime.to_unix(cp.created_at, :microsecond)

      with {:ok, _} <- Redix.command(conn, ["SET", key, serialize(cp)]),
           {:ok, _} <- Redix.command(conn, ["ZADD", index_key, score, cp.checkpoint_id]) do
        apply_ttl(conn, config, key, index_key)
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
      conn = config[:conn] || @default_conn
      thread_id = Keyword.fetch!(config, :thread_id)
      limit = Keyword.get(opts, :limit, 100)

      with {:ok, ids} <-
             Redix.command(conn, ["ZREVRANGE", thread_index_key(thread_id), "0", "#{limit - 1}"]),
           {:ok, values} <- fetch_values(conn, thread_id, ids) do
        values
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&deserialize/1)
      end
    end

    @impl true
    def delete_thread(config) do
      conn = config[:conn] || @default_conn
      thread_id = Keyword.fetch!(config, :thread_id)
      index_key = thread_index_key(thread_id)

      with {:ok, ids} <- Redix.command(conn, ["ZRANGE", index_key, "0", "-1"]),
           keys = Enum.map(ids, &checkpoint_key(thread_id, &1)),
           {:ok, _} <- Redix.command(conn, ["DEL", index_key | keys]) do
        :ok
      end
    end

    defp fetch_values(_conn, _thread_id, []), do: {:ok, []}

    defp fetch_values(conn, thread_id, ids) do
      keys = Enum.map(ids, &checkpoint_key(thread_id, &1))
      Redix.command(conn, ["MGET" | keys])
    end

    defp load_by_id(nil, config) do
      conn = config[:conn] || @default_conn
      thread_id = Keyword.fetch!(config, :thread_id)

      with {:ok, [latest_id]} <-
             Redix.command(conn, ["ZREVRANGE", thread_index_key(thread_id), "0", "0"]) do
        fetch_checkpoint(conn, thread_id, latest_id)
      else
        {:ok, []} -> :none
        {:error, _} = err -> err
      end
    end

    defp load_by_id(checkpoint_id, config) do
      conn = config[:conn] || @default_conn
      thread_id = Keyword.fetch!(config, :thread_id)
      fetch_checkpoint(conn, thread_id, checkpoint_id)
    end

    defp fetch_checkpoint(conn, thread_id, checkpoint_id) do
      conn
      |> Redix.command(["GET", checkpoint_key(thread_id, checkpoint_id)])
      |> handle_fetch()
    end

    defp handle_fetch({:ok, nil}), do: :none
    defp handle_fetch({:ok, data}), do: {:ok, deserialize(data)}
    defp handle_fetch({:error, _} = err), do: err

    defp checkpoint_key(thread_id, cp_id), do: "#{@prefix}:cp:#{thread_id}:#{cp_id}"
    defp thread_index_key(thread_id), do: "#{@prefix}:thread:#{thread_id}"

    defp apply_ttl(conn, config, key, index_key) do
      config
      |> Keyword.get(:ttl)
      |> set_expiry(conn, key, index_key)
    end

    defp set_expiry(nil, _conn, _key, _index_key), do: :ok

    defp set_expiry(ttl, conn, key, index_key) do
      Redix.command(conn, ["EXPIRE", key, "#{ttl}"])
      Redix.command(conn, ["EXPIRE", index_key, "#{ttl}"])
    end

    defp serialize(%Checkpoint{} = cp) do
      cp
      |> Serializer.encode()
      |> Jason.encode!()
    end

    defp deserialize(json) do
      json
      |> Jason.decode!()
      |> Serializer.decode()
    end
  end
end
