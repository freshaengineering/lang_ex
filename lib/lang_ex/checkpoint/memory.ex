defmodule LangEx.Checkpointer.Memory do
  @moduledoc """
  In-memory `LangEx.Checkpointer` backend.

  Checkpoints live in a public ETS table owned by the application —
  dependency-free and fast, but per-VM and lost on restart. Use for
  development, tests, and short-lived graphs; production threads that
  must survive restarts belong in `LangEx.Checkpointer.Redis` or
  `LangEx.Checkpointer.Postgres`.

      graph = Graph.compile(builder, checkpointer: LangEx.Checkpointer.Memory)

  Implements the full behaviour, including thread copying and the
  per-task write journal, so durability semantics can be exercised in
  tests without a database.
  """

  @behaviour LangEx.Checkpointer

  alias LangEx.Checkpoint
  alias LangEx.Checkpointer

  @table :lang_ex_memory_checkpoints
  @writes_table :lang_ex_memory_checkpoint_writes

  @doc false
  @spec create_table() :: :ok
  def create_table do
    @table = :ets.new(@table, [:named_table, :public, :ordered_set, read_concurrency: true])

    @writes_table =
      :ets.new(@writes_table, [:named_table, :public, :ordered_set, read_concurrency: true])

    :ok
  end

  @impl true
  def save(config, %Checkpoint{} = checkpoint) do
    thread_id = Keyword.fetch!(config, :thread_id)
    key = {thread_id, checkpoint.checkpoint_ns, :erlang.unique_integer([:monotonic])}
    :ets.insert(@table, {key, checkpoint})
    :ok
  end

  @impl true
  def load(config) do
    config
    |> namespace_checkpoints()
    |> select_checkpoint(Keyword.get(config, :checkpoint_id))
  end

  @impl true
  def list(config, opts \\ []) do
    config
    |> namespace_checkpoints()
    |> filter_source(Keyword.get(opts, :source))
    |> drop_until_after(Keyword.get(opts, :before))
    |> Enum.take(Keyword.get(opts, :limit, 100))
  end

  @impl true
  def delete_thread(config) do
    thread_id = Keyword.fetch!(config, :thread_id)
    :ets.match_delete(@table, {{thread_id, :_, :_}, :_})
    :ets.match_delete(@writes_table, {{thread_id, :_, :_, :_}, :_})
    :ok
  end

  @impl true
  def copy_thread(config, target_thread_id) do
    thread_id = Keyword.fetch!(config, :thread_id)

    @table
    |> :ets.match_object({{thread_id, :_, :_}, :_})
    |> Enum.each(&insert_copy(&1, target_thread_id))

    :ok
  end

  @impl true
  def put_writes(config, checkpoint_id, write, _opts \\ []) do
    thread_id = Keyword.fetch!(config, :thread_id)
    ns = Checkpointer.namespace(config)
    key = {thread_id, ns, anchor(checkpoint_id), {write.task_id, write.idx}}
    :ets.insert(@writes_table, {key, write})
    :ok
  end

  @impl true
  def load_writes(config, checkpoint_id) do
    thread_id = Keyword.fetch!(config, :thread_id)
    ns = Checkpointer.namespace(config)

    @writes_table
    |> :ets.match_object({{thread_id, ns, anchor(checkpoint_id), :_}, :_})
    |> Enum.sort_by(fn {{_t, _ns, _anchor, ordinal}, _write} -> ordinal end)
    |> Enum.map(fn {_key, write} -> write end)
  end

  @impl true
  def discard_writes(config, checkpoint_id) do
    thread_id = Keyword.fetch!(config, :thread_id)
    ns = Checkpointer.namespace(config)
    :ets.match_delete(@writes_table, {{thread_id, ns, anchor(checkpoint_id), :_}, :_})
    :ok
  end

  @doc "Removes every checkpoint across all threads (test helper)."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@writes_table)
    :ok
  end

  defp insert_copy({{_thread_id, ns, seq}, checkpoint}, target_thread_id) do
    :ets.insert(
      @table,
      {{target_thread_id, ns, seq}, %{checkpoint | thread_id: target_thread_id}}
    )
  end

  # The journal for a run that has not checkpointed yet anchors on a
  # sentinel rather than nil, so the ETS key stays a plain term.
  defp anchor(nil), do: :__root__
  defp anchor(checkpoint_id), do: checkpoint_id

  defp namespace_checkpoints(config) do
    thread_id = Keyword.fetch!(config, :thread_id)
    ns = Checkpointer.namespace(config)

    @table
    |> :ets.match_object({{thread_id, ns, :_}, :_})
    |> Enum.sort_by(fn {{_thread_id, _ns, seq}, _checkpoint} -> seq end, :desc)
    |> Enum.map(fn {_key, checkpoint} -> checkpoint end)
  end

  defp filter_source(checkpoints, nil), do: checkpoints

  defp filter_source(checkpoints, sources) do
    allowed = MapSet.new(List.wrap(sources))
    Enum.filter(checkpoints, &MapSet.member?(allowed, &1.source))
  end

  defp drop_until_after(checkpoints, nil), do: checkpoints

  defp drop_until_after(checkpoints, before_id) do
    checkpoints
    |> Enum.drop_while(&(&1.checkpoint_id != before_id))
    |> exclude_cursor(checkpoints, before_id)
  end

  # An unknown cursor must not silently return the whole history.
  defp exclude_cursor([], _checkpoints, before_id) do
    raise ArgumentError,
          "list/2 received :before #{inspect(before_id)}, which is not a checkpoint " <>
            "of this thread and namespace"
  end

  defp exclude_cursor([_cursor | older], _checkpoints, _before_id), do: older

  defp select_checkpoint([], _checkpoint_id), do: :none
  defp select_checkpoint([latest | _], nil), do: {:ok, latest}

  defp select_checkpoint(checkpoints, checkpoint_id) do
    checkpoints
    |> Enum.find(&(&1.checkpoint_id == checkpoint_id))
    |> wrap_found()
  end

  defp wrap_found(nil), do: :none
  defp wrap_found(checkpoint), do: {:ok, checkpoint}
end
