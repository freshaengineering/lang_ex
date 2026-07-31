defmodule Example.InMemoryCheckpointer do
  @moduledoc """
  Minimal in-memory checkpointer for the example scripts.

  Stores checkpoints per `{thread_id, checkpoint_ns}` in an Agent — newest
  first. Implements the required `LangEx.Checkpointer` callbacks, including
  loading a specific checkpoint via `:checkpoint_id` in the config (time
  travel).

  A thread and its subgraphs share one `thread_id` and are told apart by
  `checkpoint_ns` (`""` for the top-level graph, `"approval"` for a
  subgraph mounted at that node). Keying storage on the pair is what keeps
  a subgraph's checkpoints from being handed back to its parent, and what
  lets `delete_thread/1` close out an entire run tree at once.

  The optional callbacks — `put_writes/4`, `load_writes/2`,
  `discard_writes/2` (per-task durability) and `copy_thread/2` — are left
  out to keep the template small. A backend that omits them still works;
  the engine feature-detects them and falls back to whole-step durability.
  See `LangEx.Checkpointer.Memory` for an implementation of all of them.
  """

  @behaviour LangEx.Checkpointer

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl true
  def save(config, checkpoint) do
    Agent.update(__MODULE__, fn threads ->
      Map.update(threads, key(config, checkpoint), [checkpoint], &[checkpoint | &1])
    end)
  end

  @impl true
  def load(config) do
    config
    |> checkpoints()
    |> select(Keyword.get(config, :checkpoint_id))
  end

  @impl true
  def list(config, opts \\ []) do
    config
    |> checkpoints()
    |> Enum.take(Keyword.get(opts, :limit, 100))
  end

  # Deleting a thread takes every namespace with it, so closing a
  # conversation cannot leave a subgraph's transcript behind.
  @impl true
  def delete_thread(config) do
    thread_id = Keyword.fetch!(config, :thread_id)

    Agent.update(__MODULE__, fn threads ->
      Map.reject(threads, fn {{thread, _ns}, _checkpoints} -> thread == thread_id end)
    end)
  end

  defp checkpoints(config) do
    Agent.get(__MODULE__, &Map.get(&1, key(config), []))
  end

  # The checkpoint's own namespace wins on the way in: a subgraph is saved
  # through its parent's config, which does not name the child namespace.
  defp key(config, checkpoint), do: {Keyword.fetch!(config, :thread_id), checkpoint.checkpoint_ns}

  defp key(config),
    do: {Keyword.fetch!(config, :thread_id), Keyword.get(config, :checkpoint_ns, "")}

  defp select([], _checkpoint_id), do: :none
  defp select([latest | _], nil), do: {:ok, latest}

  defp select(checkpoints, checkpoint_id) do
    checkpoints
    |> Enum.find(&(&1.checkpoint_id == checkpoint_id))
    |> wrap()
  end

  defp wrap(nil), do: :none
  defp wrap(checkpoint), do: {:ok, checkpoint}
end

{:ok, _} = Example.InMemoryCheckpointer.start_link()
