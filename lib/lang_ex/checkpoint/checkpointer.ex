defmodule LangEx.Checkpointer do
  @moduledoc """
  Behaviour for checkpoint persistence backends.

  Implement this behaviour to add custom storage (e.g., S3, DynamoDB).
  Built-in implementations: `LangEx.Checkpointer.Memory`,
  `LangEx.Checkpointer.Redis`, `LangEx.Checkpointer.Postgres`.

  ## Config keys

  Every callback receives the run's `:config` keyword list. The keys a
  backend is expected to honour:

  - `:thread_id` — the conversation being persisted (required)
  - `:checkpoint_ns` — position within the thread's graph tree (default
    `""`, the root graph). `load/1` and `list/2` are scoped to one
    namespace; `delete_thread/1` and `copy_thread/2` span all of them.
  - `:checkpoint_id` — pins `load/1` to one checkpoint (time travel)

  Backend-specific keys (`:repo`, `:conn`, `:ttl`, ...) travel in the same
  list.

  ## Optional callbacks

  `put_writes/4`, `load_writes/2`, and `copy_thread/2` are optional. The
  engine feature-detects them, so an existing backend keeps working
  without them — it simply falls back to whole-super-step durability and
  cannot branch threads. Implement `put_writes/4` and `load_writes/2`
  together; a journal that cannot be read back is never consulted.
  """

  alias LangEx.Checkpoint

  @type config :: keyword()

  @typedoc """
  One completed unit of work within a super-step, recorded before the
  super-step's checkpoint exists.
  """
  @type write :: %{
          task_id: String.t(),
          node: atom(),
          update: term(),
          idx: non_neg_integer()
        }

  @doc "Persists a checkpoint."
  @callback save(config(), Checkpoint.t()) :: :ok | {:error, term()}

  @doc """
  Loads the latest checkpoint for the thread and namespace in the config.

  When the config includes a `:checkpoint_id`, that specific checkpoint
  is loaded instead (time travel / forking).
  """
  @callback load(config()) :: {:ok, Checkpoint.t()} | :none | {:error, term()}

  @doc """
  Lists checkpoints for a thread and namespace, most recent first.

  Options:

  - `:limit` — maximum rows returned (default `100`)
  - `:before` — a `checkpoint_id` cursor; only strictly older checkpoints
    are returned, for keyset pagination through a long history
  - `:source` — restrict to one or more `Checkpoint.source()` values
  """
  @callback list(config(), keyword()) :: [Checkpoint.t()] | {:error, term()}

  @doc """
  Deletes every checkpoint belonging to the thread in the config, across
  all namespaces — subgraph checkpoints included.
  """
  @callback delete_thread(config()) :: :ok | {:error, term()}

  @doc """
  Copies every checkpoint of `:thread_id` onto the target thread, across
  all namespaces, preserving checkpoint IDs and lineage.

  The safe primitive for branching a conversation: the copy shares no
  rows with the original, so writing to either leaves the other intact.
  """
  @callback copy_thread(config(), target_thread_id :: String.t()) :: :ok | {:error, term()}

  @doc """
  Journals one completed unit of work against a checkpoint that has not
  been written yet.

  Called as each node in a super-step finishes, so a crash mid-step does
  not discard the work that already succeeded. `checkpoint_id` is the
  parent checkpoint the step started from — the anchor the journal is
  replayed against on resume.
  """
  @callback put_writes(config(), checkpoint_id :: String.t() | nil, write(), keyword()) ::
              :ok | {:error, term()}

  @doc """
  Loads the journaled writes anchored to a checkpoint, oldest first.

  Returns `[]` when the step completed cleanly and its journal was
  discarded.
  """
  @callback load_writes(config(), checkpoint_id :: String.t() | nil) :: [write()]

  @doc """
  Discards the journal anchored to a checkpoint.

  Called once the super-step's own checkpoint is durable, at which point
  the journal is redundant.
  """
  @callback discard_writes(config(), checkpoint_id :: String.t() | nil) :: :ok | {:error, term()}

  @optional_callbacks copy_thread: 2, put_writes: 4, load_writes: 2, discard_writes: 2

  @doc """
  Whether `checkpointer` implements the optional journal callbacks.

  Both writing and reading must be present for the engine to rely on
  per-task durability.
  """
  @spec journals?(module()) :: boolean()
  def journals?(nil), do: false

  def journals?(checkpointer) do
    Code.ensure_loaded?(checkpointer) and
      function_exported?(checkpointer, :put_writes, 4) and
      function_exported?(checkpointer, :load_writes, 2)
  end

  @doc "The namespace in a run config, defaulting to the root graph."
  @spec namespace(config()) :: String.t()
  def namespace(config), do: Keyword.get(config, :checkpoint_ns) || ""
end
