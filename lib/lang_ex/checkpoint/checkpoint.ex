defmodule LangEx.Checkpoint do
  @moduledoc """
  Data structure representing a saved graph execution snapshot.

  Persisted by checkpointer implementations after each super-step,
  enabling pause/resume, time-travel, and fault recovery.

  `next_nodes` holds full work entries — node names or `%LangEx.Send{}`
  structs — so Send payloads survive crash-continue and interrupt-resume
  (format version 2). Version 1 checkpoints, which stored node names
  only, still load and resume; only Send payloads from that era are
  unrecoverable.

  ## Namespaces

  `checkpoint_ns` locates a checkpoint within a thread's graph tree
  (format version 3). The root graph writes under `""`; a subgraph node
  writes under its own path (`"planner"`, and `"planner|research"` when
  nested), all sharing the parent's `thread_id`. One thread ID therefore
  addresses an entire run, which is what lets `delete_thread/1` remove a
  conversation completely and lets a fork reposition its subgraphs.
  `metadata.parents` records the enclosing namespace's checkpoint ID at
  write time, so lineage stays reconstructable across graph boundaries.

  ## Provenance

  `source` records why a checkpoint exists:

  - `:input` — the run's starting state, before any node executed
  - `:step` — written by the engine at a super-step boundary
  - `:update` — written by `LangEx.update_state/3`
  - `:fork` — written by `LangEx.update_state/3` against a historical
    checkpoint, branching the thread

  Checkpoints written before format version 3 load with
  `checkpoint_ns: ""` and `source: :step`.
  """

  @format_version 3

  @sources [:input, :step, :update, :fork]

  defstruct [
    :thread_id,
    :checkpoint_id,
    :parent_id,
    :state,
    :next_nodes,
    :step,
    :metadata,
    :pending_interrupts,
    :created_at,
    checkpoint_ns: "",
    source: :step,
    version: @format_version
  ]

  @type source :: :input | :step | :update | :fork

  @type t :: %__MODULE__{
          thread_id: String.t(),
          checkpoint_ns: String.t(),
          checkpoint_id: String.t(),
          parent_id: String.t() | nil,
          state: map(),
          next_nodes: [atom() | LangEx.Send.t()],
          step: non_neg_integer(),
          metadata: map(),
          pending_interrupts: [map()] | nil,
          created_at: DateTime.t(),
          source: source(),
          version: pos_integer()
        }

  @doc "Builds a new checkpoint with an auto-generated ID and timestamp."
  @spec new(keyword()) :: t()
  def new(attrs) do
    struct!(
      __MODULE__,
      Keyword.merge(
        [checkpoint_id: generate_id(), created_at: DateTime.utc_now(), version: @format_version],
        attrs
      )
    )
  end

  @doc "Current checkpoint format version, persisted with every checkpoint."
  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @doc "The valid `:source` values."
  @spec sources() :: [source()]
  def sources, do: @sources

  @doc """
  The namespace a subgraph node writes under, given its parent's namespace.

      iex> LangEx.Checkpoint.child_ns("", :planner)
      "planner"
      iex> LangEx.Checkpoint.child_ns("planner", :research)
      "planner|research"
  """
  @spec child_ns(String.t(), atom() | String.t()) :: String.t()
  def child_ns("", name), do: to_string(name)
  def child_ns(parent_ns, name), do: "#{parent_ns}|#{name}"

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
