defmodule LangEx.Checkpointer.Memory do
  @moduledoc """
  In-memory `LangEx.Checkpointer` backend.

  Checkpoints live in a public ETS table owned by the application —
  dependency-free and fast, but per-VM and lost on restart. Use for
  development, tests, and short-lived graphs; production threads that
  must survive restarts belong in `LangEx.Checkpointer.Redis` or
  `LangEx.Checkpointer.Postgres`.

      graph = Graph.compile(builder, checkpointer: LangEx.Checkpointer.Memory)
  """

  @behaviour LangEx.Checkpointer

  alias LangEx.Checkpoint

  @table :lang_ex_memory_checkpoints

  @doc false
  @spec create_table() :: :ok
  def create_table do
    @table = :ets.new(@table, [:named_table, :public, :ordered_set, read_concurrency: true])
    :ok
  end

  @impl true
  def save(config, %Checkpoint{} = checkpoint) do
    thread_id = Keyword.fetch!(config, :thread_id)
    :ets.insert(@table, {{thread_id, :erlang.unique_integer([:monotonic])}, checkpoint})
    :ok
  end

  @impl true
  def load(config) do
    config
    |> thread_checkpoints()
    |> select_checkpoint(Keyword.get(config, :checkpoint_id))
  end

  @impl true
  def list(config, opts \\ []) do
    config
    |> thread_checkpoints()
    |> Enum.take(Keyword.get(opts, :limit, 100))
  end

  @impl true
  def delete_thread(config) do
    thread_id = Keyword.fetch!(config, :thread_id)
    :ets.match_delete(@table, {{thread_id, :_}, :_})
    :ok
  end

  @doc "Removes every checkpoint across all threads (test helper)."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp thread_checkpoints(config) do
    thread_id = Keyword.fetch!(config, :thread_id)

    @table
    |> :ets.match_object({{thread_id, :_}, :_})
    |> Enum.sort_by(fn {{_thread_id, seq}, _checkpoint} -> seq end, :desc)
    |> Enum.map(fn {_key, checkpoint} -> checkpoint end)
  end

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
