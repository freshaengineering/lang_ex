defmodule LangEx.Checkpointer.Mock do
  @moduledoc false
  @behaviour LangEx.Checkpointer

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl true
  def save(config, checkpoint) do
    thread_id = Keyword.fetch!(config, :thread_id)

    Agent.update(__MODULE__, fn state ->
      existing = Map.get(state, thread_id, [])
      Map.put(state, thread_id, [checkpoint | existing])
    end)

    :ok
  end

  @impl true
  def load(config) do
    thread_id = Keyword.fetch!(config, :thread_id)

    __MODULE__
    |> Agent.get(&Map.get(&1, thread_id, []))
    |> select_checkpoint(Keyword.get(config, :checkpoint_id))
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

  @impl true
  def list(config, _opts \\ []) do
    thread_id = Keyword.fetch!(config, :thread_id)
    Agent.get(__MODULE__, &Map.get(&1, thread_id, []))
  end

  def clear do
    Agent.update(__MODULE__, fn _ -> %{} end)
  end
end
