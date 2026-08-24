defmodule LangEx.Checkpoint.Codec do
  @moduledoc """
  Behaviour and resolver for checkpoint payload encoding.

  Persisting backends encode through this module rather than calling a
  serializer directly, so the wire format is a deployment decision. The
  default, `LangEx.Checkpoint.Serializer`, is a lossless tagged-JSON
  codec. Swap in `LangEx.Checkpoint.Codec.Encrypted` to keep conversation
  state unreadable at rest, or a custom module to match an existing
  storage convention.

  ## Selecting a codec

  Per run, alongside the rest of the checkpointer config:

      config = [repo: MyApp.Repo, thread_id: "t-1", serializer: MyCodec]

  Or application-wide:

      config :lang_ex, checkpoint_serializer: MyCodec

  A codec receives the same config on both sides of the round-trip, which
  is where implementations read their own options (keys, allowlists).

  ## Implementing one

  Both callbacks take the config so a codec can vary its behaviour per
  thread. `decode/2` must accept anything `encode/2` produced, including
  payloads written by earlier configurations of the same codec —
  checkpoints outlive deploys, so dropping support for an old shape makes
  live threads unresumable.
  """

  @callback encode(term(), keyword()) :: term()
  @callback decode(term(), keyword()) :: term()

  @default LangEx.Checkpoint.Serializer

  @doc "Encodes a term for storage using the codec selected by `config`."
  @spec encode(term(), keyword()) :: term()
  def encode(term, config), do: config |> impl() |> apply(:encode, [term, config])

  @doc "Decodes a stored term using the codec selected by `config`."
  @spec decode(term(), keyword()) :: term()
  def decode(term, config), do: config |> impl() |> apply(:decode, [term, config])

  @doc "The codec module `config` selects."
  @spec impl(keyword()) :: module()
  def impl(config) do
    Keyword.get(config, :serializer) ||
      Application.get_env(:lang_ex, :checkpoint_serializer, @default)
  end
end
