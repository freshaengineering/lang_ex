defmodule Example.InMemoryCheckpointer do
  @moduledoc """
  Minimal in-memory checkpointer for the example scripts.

  Stores checkpoints per thread in an Agent — newest first. Implements
  the full `LangEx.Checkpointer` behaviour, including loading a specific
  checkpoint via `:checkpoint_id` in the config (time travel).
  """

  @behaviour LangEx.Checkpointer

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl true
  def save(config, checkpoint) do
    thread_id = Keyword.fetch!(config, :thread_id)

    Agent.update(__MODULE__, fn threads ->
      Map.update(threads, thread_id, [checkpoint], &[checkpoint | &1])
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

  defp checkpoints(config) do
    thread_id = Keyword.fetch!(config, :thread_id)
    Agent.get(__MODULE__, &Map.get(&1, thread_id, []))
  end

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
