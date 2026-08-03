# Checkpoints that are unreadable at rest.
#
# Graph state is the most sensitive thing a durable agent holds: whole
# transcripts, tool arguments, retrieved documents. A codec sits between
# the engine and the storage backend, so the payload is encrypted inside
# the application and the database only ever sees ciphertext.
#
# Values are sealed one by one, so an allowlist can keep operational keys
# readable, and each value records the key ID it was sealed with, so keys
# can be rotated without stranding live threads.
#
# The checkpointer here stores the encoded payload in an Agent and prints
# it — standing in for the row a real backend would write.
#
# Run: elixir examples/scripts/19_encrypted_checkpoints.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule Example.EncodingCheckpointer do
  @moduledoc """
  Checkpointer that keeps state in its encoded (wire) form.

  Persisting backends encode through `LangEx.Checkpoint.Codec` rather than
  serializing themselves, which is what makes the format a deployment
  choice. This one does the same and keeps the result in memory, so the
  bytes a database would hold can be inspected.
  """

  @behaviour LangEx.Checkpointer

  use Agent

  alias LangEx.Checkpoint.Codec

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl true
  def save(config, checkpoint) do
    row = %{checkpoint | state: Codec.encode(checkpoint.state, config)}

    Agent.update(__MODULE__, fn threads ->
      Map.update(threads, key(config, checkpoint), [row], &[row | &1])
    end)
  end

  @impl true
  def load(config) do
    config
    |> rows()
    |> Enum.take(1)
    |> decode_first(config)
  end

  @impl true
  def list(config, opts \\ []) do
    config
    |> rows()
    |> Enum.take(Keyword.get(opts, :limit, 100))
    |> Enum.map(&decode(&1, config))
  end

  @impl true
  def delete_thread(config) do
    thread_id = Keyword.fetch!(config, :thread_id)

    Agent.update(
      __MODULE__,
      &Map.reject(&1, fn {{thread, _ns}, _rows} -> thread == thread_id end)
    )
  end

  @doc "The stored payload for a thread's newest checkpoint, still encoded."
  def stored_state(config) do
    config
    |> rows()
    |> hd()
    |> Map.fetch!(:state)
  end

  defp rows(config), do: Agent.get(__MODULE__, &Map.get(&1, key(config), []))

  defp decode_first([], _config), do: :none
  defp decode_first([row], config), do: {:ok, decode(row, config)}

  defp decode(row, config), do: %{row | state: Codec.decode(row.state, config)}

  defp key(config, checkpoint), do: {Keyword.fetch!(config, :thread_id), checkpoint.checkpoint_ns}

  defp key(config),
    do: {Keyword.fetch!(config, :thread_id), Keyword.get(config, :checkpoint_ns, "")}
end

{:ok, _} = Example.EncodingCheckpointer.start_link()

defmodule EncryptedDemo do
  alias Example.EncodingCheckpointer
  alias LangEx.Checkpoint.Codec.Encrypted
  alias LangEx.Graph

  # In a real system these come from a secret manager at runtime. Never
  # commit a key or put one in a migration.
  @keys %{
    "2026-06" => :crypto.strong_rand_bytes(32),
    "2026-07" => :crypto.strong_rand_bytes(32)
  }

  def run do
    graph = build()

    # Sealed with the June key. `:case_id` is allowlisted, so it stays
    # readable for support tooling while the transcript does not.
    june = crypto("case-1", "2026-06")
    input = %{case_id: "case-1", note: "card ending 4321"}
    {:ok, result} = LangEx.invoke(graph, input, config: june)

    IO.puts("in state: #{inspect(result.summary)}")
    IO.puts("\non the wire:")
    Enum.each(wire_pairs(june), fn {key, value} -> IO.puts("  #{key}: #{value}") end)

    # Reading it back through the same config decrypts transparently.
    {:ok, loaded} = LangEx.get_state(graph, config: june)
    IO.puts("\nround-tripped: #{inspect(loaded.state.summary)}")

    # Rotation: point at the July key, keeping June available. New writes
    # are sealed under "2026-07"; the June thread still reads.
    july = crypto("case-2", "2026-07")
    {:ok, _} = LangEx.invoke(graph, %{case_id: "case-2", note: "card ending 9876"}, config: july)

    IO.puts(
      "\nkey IDs in use: #{inspect(%{"case-1" => key_ids(june), "case-2" => key_ids(july)})}"
    )

    {:ok, still_readable} = LangEx.get_state(graph, config: june)
    IO.puts("case-1 after rotation: #{inspect(still_readable.state.summary)}")

    # Retiring a key that a live thread still references makes the failure
    # explicit rather than silent corruption.
    IO.puts("\nreading case-1 with June retired: #{inspect(read_without_june(graph))}")
  end

  defp build do
    Graph.new(case_id: nil, note: nil, summary: nil)
    |> Graph.add_node(:triage, fn state ->
      %{summary: "#{state.case_id}: dispute on #{state.note}"}
    end)
    |> Graph.add_edge(:__start__, :triage)
    |> Graph.add_edge(:triage, :__end__)
    |> Graph.compile(name: :disputes, checkpointer: EncodingCheckpointer)
  end

  # Codec options travel with the run config, so a codec can vary its
  # behaviour per thread (a tenant's own key, a stricter allowlist).
  defp crypto(thread_id, key_id) do
    [
      thread_id: thread_id,
      serializer: Encrypted,
      encryption_keys: @keys,
      encryption_key_id: key_id,
      plaintext_keys: [:case_id]
    ]
  end

  # Every sealed value carries the ID of the key that sealed it.
  defp key_ids(config) do
    config
    |> encoded_pairs()
    |> Enum.flat_map(fn [_key, value] -> sealed_with(value) end)
    |> Enum.uniq()
  end

  defp sealed_with(%{"~e" => [key_id, _payload]}), do: [key_id]
  defp sealed_with(_plaintext), do: []

  defp wire_pairs(config) do
    config
    |> encoded_pairs()
    |> Enum.map(fn [%{"~a" => name}, value] -> {name, describe(value)} end)
  end

  defp describe(%{"~e" => [key_id, payload]}),
    do: "sealed with #{key_id} — #{String.slice(payload, 0, 32)}…"

  defp describe(plaintext), do: "#{inspect(plaintext)} (allowlisted, in the clear)"

  defp encoded_pairs(config) do
    config
    |> EncodingCheckpointer.stored_state()
    |> Map.fetch!("~m")
  end

  defp read_without_june(graph) do
    LangEx.get_state(graph,
      config: "case-1" |> crypto("2026-07") |> Keyword.put(:encryption_keys, july_only())
    )
  rescue
    error in ArgumentError -> Exception.message(error)
  end

  defp july_only, do: Map.take(@keys, ["2026-07"])
end

EncryptedDemo.run()
