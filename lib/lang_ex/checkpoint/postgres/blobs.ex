defmodule LangEx.Checkpointer.Postgres.Blobs do
  @moduledoc false

  # Content-addressed extraction of large state values from an encoded
  # checkpoint. The dominant checkpoint cost is large values that never
  # change between super-steps (e.g. hundreds of KB of tool specs
  # re-serialized into every row). Values above the threshold are pulled
  # into a side table keyed by (thread_id, content hash) — identical
  # content is stored once per thread regardless of how many checkpoints
  # reference it — and replaced inline with a `%{"~blob" => hash}` marker
  # that `resolve/2` splices back before decoding.

  @marker "~blob"

  @doc "Splits large values out of an encoded state map. Returns {slim, blobs}."
  @spec split(term(), pos_integer() | :infinity) :: {term(), %{String.t() => term()}}
  def split(encoded, :infinity), do: {encoded, %{}}

  def split(%{"~m" => pairs} = encoded, threshold) when is_list(pairs) do
    {slim_pairs, blobs} = Enum.map_reduce(pairs, %{}, &split_pair(&1, &2, threshold))
    {%{encoded | "~m" => slim_pairs}, blobs}
  end

  def split(encoded, _threshold), do: {encoded, %{}}

  @doc """
  Resolves `%{"~blob" => hash}` markers in an encoded state map.

  `fetch` receives the list of hashes and must return a
  `%{hash => value}` map. Raises when a referenced blob is missing —
  a dangling reference means the blob store was pruned out from under
  live checkpoints.
  """
  @spec resolve(term(), ([String.t()] -> %{String.t() => term()})) :: term()
  def resolve(%{"~m" => pairs} = encoded, fetch) when is_list(pairs) do
    pairs
    |> Enum.flat_map(&pair_hash/1)
    |> splice(pairs, encoded, fetch)
  end

  def resolve(encoded, _fetch), do: encoded

  defp splice([], _pairs, encoded, _fetch), do: encoded

  defp splice(hashes, pairs, encoded, fetch) do
    values = fetch.(hashes)
    %{encoded | "~m" => Enum.map(pairs, &resolve_pair(&1, values))}
  end

  defp split_pair([key, value], blobs, threshold) do
    value
    |> :erlang.term_to_binary()
    |> blob_or_inline(key, value, blobs, threshold)
  end

  defp blob_or_inline(binary, key, value, blobs, threshold)
       when byte_size(binary) > threshold do
    hash = Base.encode16(:crypto.hash(:sha256, binary), case: :lower)
    {[key, %{@marker => hash}], Map.put(blobs, hash, value)}
  end

  defp blob_or_inline(_binary, key, value, blobs, _threshold), do: {[key, value], blobs}

  defp pair_hash([_key, %{@marker => hash}]), do: [hash]
  defp pair_hash(_pair), do: []

  defp resolve_pair([key, %{@marker => hash}], values) do
    values
    |> Map.fetch(hash)
    |> require_blob!(hash)
    |> then(&[key, &1])
  end

  defp resolve_pair(pair, _values), do: pair

  defp require_blob!({:ok, value}, _hash), do: value

  defp require_blob!(:error, hash) do
    raise ArgumentError,
          "checkpoint references missing blob #{hash} — " <>
            "the blob store was pruned out from under a live checkpoint"
  end
end
