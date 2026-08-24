defmodule LangEx.Checkpoint.Codec.Encrypted do
  @moduledoc """
  Encrypts checkpoint payloads at rest with AES-256-GCM.

  Graph state is the most sensitive data a durable agent holds — full
  conversation transcripts, tool arguments, retrieved documents. This
  codec encrypts it inside the application, so a database dump, replica,
  or backup carries ciphertext rather than transcripts, and the storage
  layer never sees a key.

  Values are encrypted individually rather than as one opaque blob, and
  an allowlist keeps chosen state keys in the clear so operational fields
  stay readable and queryable:

      config = [
        repo: MyApp.Repo,
        thread_id: "t-1",
        serializer: LangEx.Checkpoint.Codec.Encrypted,
        encryption_keys: %{"2026-07" => key},
        encryption_key_id: "2026-07",
        plaintext_keys: [:status, :user_id]
      ]

  Keys are 32 raw bytes (`:crypto.strong_rand_bytes(32)`). Read them from
  your secret manager at runtime; never commit one or put it in a
  migration.

  ## Key rotation

  `encryption_keys` is a map of key ID to key, and every value records the
  ID it was sealed with. Rotating means adding a new key, pointing
  `encryption_key_id` at it, and keeping the old entries so existing
  threads still decrypt. Retire an old key only once no live thread
  references it.

  Authentication is bound to the key ID, so a value cannot be replayed
  under a different key, and tampering fails loudly rather than decoding
  to garbage.
  """

  @behaviour LangEx.Checkpoint.Codec

  alias LangEx.Checkpoint.Serializer

  @marker "~e"
  @cipher :aes_256_gcm
  @iv_bytes 12
  @tag_bytes 16

  @doc false
  @impl true
  def encode(term, config) do
    term
    |> Serializer.encode()
    |> seal(config)
  end

  @doc false
  @impl true
  def decode(term, config) do
    term
    |> open(config)
    |> Serializer.decode()
  end

  # State and metadata encode to a tagged map, whose values are encrypted
  # pair-by-pair so the allowlist can operate at the state-key level.
  # Anything else is sealed whole.
  defp seal(%{"~m" => pairs} = encoded, config) when is_list(pairs) do
    plaintext = plaintext_keys(config)
    %{encoded | "~m" => Enum.map(pairs, &seal_pair(&1, plaintext, config))}
  end

  defp seal(encoded, config), do: encrypt(encoded, config)

  defp seal_pair([key, value], plaintext, config) do
    plaintext
    |> MapSet.member?(key)
    |> keep_or_encrypt(key, value, config)
  end

  defp keep_or_encrypt(true, key, value, _config), do: [key, value]
  defp keep_or_encrypt(false, key, value, config), do: [key, encrypt(value, config)]

  defp open(%{@marker => _} = envelope, config), do: decrypt(envelope, config)

  defp open(%{"~m" => pairs} = encoded, config) when is_list(pairs) do
    %{encoded | "~m" => Enum.map(pairs, fn [key, value] -> [key, open(value, config)] end)}
  end

  defp open(encoded, _config), do: encoded

  defp encrypt(value, config) do
    {key_id, key} = active_key(config)
    iv = :crypto.strong_rand_bytes(@iv_bytes)
    plaintext = :erlang.term_to_binary(value)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(@cipher, key, iv, plaintext, key_id, @tag_bytes, true)

    %{@marker => [key_id, Base.encode64(iv <> tag <> ciphertext)]}
  end

  defp decrypt(%{@marker => [key_id, payload]}, config) do
    <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>> =
      Base.decode64!(payload)

    @cipher
    |> :crypto.crypto_one_time_aead(key_for!(config, key_id), iv, ciphertext, key_id, tag, false)
    |> restore!(key_id)
  end

  defp restore!(:error, key_id) do
    raise ArgumentError,
          "checkpoint value failed authentication under key #{inspect(key_id)} — " <>
            "the stored data was modified, or the configured key does not match " <>
            "the one it was sealed with"
  end

  defp restore!(plaintext, _key_id),
    do: :erlang.binary_to_term(plaintext, [:safe])

  defp active_key(config) do
    key_id = Keyword.get(config, :encryption_key_id) || sole_key_id!(config)
    {key_id, key_for!(config, key_id)}
  end

  defp sole_key_id!(config) do
    config
    |> keys!()
    |> Map.keys()
    |> single_key_id!()
  end

  defp single_key_id!([key_id]), do: key_id

  defp single_key_id!(key_ids) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} needs :encryption_key_id to choose among " <>
            "#{inspect(Enum.sort(key_ids))}"
  end

  defp key_for!(config, key_id) do
    config
    |> keys!()
    |> Map.fetch(key_id)
    |> require_key!(key_id)
  end

  defp require_key!({:ok, key}, key_id) when byte_size(key) == 32 do
    _ = key_id
    key
  end

  defp require_key!({:ok, key}, key_id) do
    raise ArgumentError,
          "encryption key #{inspect(key_id)} is #{byte_size(key)} bytes — " <>
            "AES-256-GCM needs exactly 32"
  end

  defp require_key!(:error, key_id) do
    raise ArgumentError,
          "no encryption key configured for #{inspect(key_id)} — a checkpoint " <>
            "sealed with a retired key cannot be read; restore it in " <>
            ":encryption_keys to resume this thread"
  end

  defp keys!(config) do
    config
    |> Keyword.get(:encryption_keys)
    |> require_keys!()
  end

  defp require_keys!(keys) when is_map(keys) and map_size(keys) > 0, do: keys

  defp require_keys!(_keys) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} requires :encryption_keys — a map of key ID " <>
            "to 32-byte key, e.g. %{\"v1\" => :crypto.strong_rand_bytes(32)}"
  end

  defp plaintext_keys(config) do
    config
    |> Keyword.get(:plaintext_keys, [])
    |> Enum.map(&Serializer.encode/1)
    |> MapSet.new()
  end
end
