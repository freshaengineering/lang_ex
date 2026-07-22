defmodule LangEx.Embedding.Hashing do
  @moduledoc """
  Dependency-free text embedder using the hashing trick.

  Tokenizes text and hashes each token into one of `:dims` buckets,
  producing a fixed-length term-frequency vector. Cosine similarity over
  these vectors approximates lexical overlap, so it needs no model and no
  network — a sensible default embedder for `LangEx.Store` semantic search
  when a neural embedding provider is not configured:

      Graph.compile(builder,
        store: {LangEx.Store.ETS, index: [embed: &LangEx.Embedding.Hashing.embed/1]}
      )

  It captures word overlap, not meaning: "db is slow" and "database
  latency" share no tokens and score near zero. Supply a neural embedder
  when semantic (meaning-based) similarity matters.
  """

  @default_dims 256

  @doc """
  Embeds `text` into a fixed-length term-frequency vector.

  Options:

  - `:dims` - vector length / number of hash buckets (default `#{@default_dims}`)
  """
  @spec embed(String.t(), keyword()) :: [float()]
  def embed(text, opts \\ []) when is_binary(text) do
    dims = Keyword.get(opts, :dims, @default_dims)
    counts = text |> tokenize() |> Enum.frequencies_by(&bucket(&1, dims))

    Enum.map(0..(dims - 1), fn index -> (counts[index] || 0) * 1.0 end)
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
  end

  defp bucket(token, dims), do: :erlang.phash2(token, dims)
end
