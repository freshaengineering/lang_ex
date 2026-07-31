defmodule LangEx.Graph.Journal do
  @moduledoc """
  Per-task durability for a super-step in progress.

  A checkpoint is written at super-step boundaries, so a crash midway
  through a step discards every node that already succeeded — including
  the expensive ones. The journal closes that window: each unit of work
  reports its result the moment it finishes, anchored to the checkpoint
  the step started from. Recovering the run replays those results instead
  of calling the nodes again, so a crash costs only the work that was
  genuinely in flight.

  Replay is deliberately narrow. It applies only when the run is
  continuing from a checkpoint, keyed by the same anchor and step that
  produced the entries, and only to units that completed normally —
  interrupts and failures are not journaled, since the checkpoint already
  carries what is needed to resume them. A fresh run never consults a
  journal, so leftover entries from an abandoned run cannot leak into a
  new one.

  The journal is redundant the instant the super-step's own checkpoint is
  durable, and is discarded there.

  Backends opt in by implementing the optional `put_writes/4`,
  `load_writes/2`, and `discard_writes/2` callbacks of
  `LangEx.Checkpointer`. Without them the engine falls back to
  whole-super-step durability.
  """

  alias LangEx.Checkpointer

  @root "~root"

  @typedoc "Replay map from a work entry's task key to its recorded update."
  @type replay :: %{String.t() => term()}

  @doc """
  Loads the replay map for the super-step described by `opts`.

  Returns an empty map when the backend has no journal, when the run is
  starting fresh, or when the previous attempt at this step recorded
  nothing.
  """
  @spec load(map()) :: replay()
  def load(opts) do
    opts
    |> enabled?()
    |> fetch_writes(opts)
  end

  @doc """
  Records one completed unit of work.

  `task_key` must be the same value the engine uses to identify the entry
  on replay, so a Send's stamped ID distinguishes fan-out branches.
  """
  @spec record(map(), String.t(), atom(), term()) :: :ok
  def record(opts, task_key, node, update) do
    opts
    |> enabled?()
    |> write(opts, task_key, node, update)
  end

  @doc """
  Discards the journal anchored to `parent_id` at `step`.

  Called once the super-step's checkpoint is durable.
  """
  @spec discard(module() | nil, keyword(), String.t() | nil, non_neg_integer()) :: :ok
  def discard(nil, _config, _parent_id, _step), do: :ok

  def discard(checkpointer, config, parent_id, step) do
    checkpointer
    |> supported?()
    |> drop(checkpointer, config, anchor(parent_id, step))
  end

  # A journal is only trustworthy when anchored to a checkpoint that
  # exists. `:parent_id` is nil exactly when no checkpoint precedes this
  # step — a fresh run, or `durability: :exit`, both of which recover by
  # restarting rather than replaying.
  defp enabled?(%{checkpointer: cp} = opts) do
    supported?(cp) and not is_nil(Map.get(opts, :parent_id))
  end

  defp supported?(cp) do
    Checkpointer.journals?(cp) and function_exported?(cp, :discard_writes, 2)
  end

  defp fetch_writes(false, _opts), do: %{}

  defp fetch_writes(true, %{checkpointer: cp, config: config} = opts) do
    cp
    |> apply(:load_writes, [config, anchor(Map.get(opts, :parent_id), opts.step)])
    |> Map.new(fn write -> {write.task_id, write.update} end)
  end

  defp write(false, _opts, _task_key, _node, _update), do: :ok

  defp write(true, %{checkpointer: cp, config: config} = opts, task_key, node, update) do
    entry = %{task_id: task_key, node: node, update: update, idx: opts.step}
    apply(cp, :put_writes, [config, anchor(Map.get(opts, :parent_id), opts.step), entry, []])
    :ok
  end

  defp drop(false, _cp, _config, _anchor), do: :ok

  defp drop(true, cp, config, anchor) do
    apply(cp, :discard_writes, [config, anchor])
    :ok
  end

  # The anchor pins a journal to one attempt at one step. Including the
  # step keeps entries from an earlier step being replayed into a later
  # one when several steps share a parent checkpoint.
  defp anchor(nil, step), do: "#{@root}:#{step}"
  defp anchor(parent_id, step), do: "#{parent_id}:#{step}"
end
