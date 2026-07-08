defmodule LangEx.Checkpointer.MemoryTest do
  use ExUnit.Case, async: true

  alias LangEx.Checkpoint
  alias LangEx.Checkpointer.Memory

  defp checkpoint(thread_id, step) do
    Checkpoint.new(
      thread_id: thread_id,
      state: %{step: step},
      next_nodes: [:worker],
      step: step,
      metadata: %{}
    )
  end

  test "load returns :none for an unknown thread" do
    assert Memory.load(thread_id: "memory-missing") == :none
  end

  test "load returns the most recently saved checkpoint" do
    thread = "memory-latest-#{System.unique_integer()}"
    :ok = Memory.save([thread_id: thread], checkpoint(thread, 0))
    :ok = Memory.save([thread_id: thread], checkpoint(thread, 1))

    assert {:ok, %Checkpoint{step: 1}} = Memory.load(thread_id: thread)
  end

  test "load by checkpoint_id returns that exact checkpoint" do
    thread = "memory-by-id-#{System.unique_integer()}"
    first = checkpoint(thread, 0)
    :ok = Memory.save([thread_id: thread], first)
    :ok = Memory.save([thread_id: thread], checkpoint(thread, 1))

    assert {:ok, %Checkpoint{step: 0}} =
             Memory.load(thread_id: thread, checkpoint_id: first.checkpoint_id)

    assert Memory.load(thread_id: thread, checkpoint_id: "nope") == :none
  end

  test "list returns most recent first and honors :limit" do
    thread = "memory-list-#{System.unique_integer()}"
    Enum.each(0..4, &Memory.save([thread_id: thread], checkpoint(thread, &1)))

    assert [%Checkpoint{step: 4}, %Checkpoint{step: 3}] =
             Memory.list([thread_id: thread], limit: 2)
  end

  test "delete_thread removes only that thread" do
    doomed = "memory-doomed-#{System.unique_integer()}"
    kept = "memory-kept-#{System.unique_integer()}"
    :ok = Memory.save([thread_id: doomed], checkpoint(doomed, 0))
    :ok = Memory.save([thread_id: kept], checkpoint(kept, 0))

    :ok = Memory.delete_thread(thread_id: doomed)

    assert Memory.load(thread_id: doomed) == :none
    assert {:ok, _} = Memory.load(thread_id: kept)
  end
end
