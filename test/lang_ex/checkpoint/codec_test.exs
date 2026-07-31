defmodule LangEx.Checkpoint.CodecTest do
  use ExUnit.Case, async: true

  alias LangEx.Checkpoint.Codec
  alias LangEx.Checkpoint.Codec.Encrypted
  alias LangEx.Checkpoint.Serializer
  alias LangEx.Message

  defmodule UpcasingCodec do
    @moduledoc false
    @behaviour LangEx.Checkpoint.Codec

    @impl true
    def encode(term, _config), do: %{"upper" => term |> inspect() |> String.upcase()}

    @impl true
    def decode(%{"upper" => text}, _config), do: text
  end

  describe "codec selection" do
    test "defaults to the lossless tagged serializer" do
      assert Codec.impl([]) == Serializer
    end

    test "the run config selects a codec" do
      assert Codec.impl(serializer: UpcasingCodec) == UpcasingCodec
    end

    test "a custom codec owns both sides of the round-trip" do
      encoded = Codec.encode(:hello, serializer: UpcasingCodec)

      assert Codec.decode(encoded, serializer: UpcasingCodec) == ":HELLO"
    end
  end

  describe "encryption" do
    setup do
      key = :crypto.strong_rand_bytes(32)
      {:ok, config: [serializer: Encrypted, encryption_keys: %{"v1" => key}], key: key}
    end

    test "state round-trips through encryption unchanged", %{config: config} do
      state = %{
        messages: [Message.human("my medical history"), Message.ai("noted")],
        count: 3,
        tags: {:a, :b}
      }

      encoded = Codec.encode(state, config)

      assert Codec.decode(encoded, config) == state
    end

    test "sensitive values are not recoverable from the encoded payload", %{config: config} do
      encoded = Codec.encode(%{secret: "swordfish"}, config)

      refute encoded |> inspect() |> String.contains?("swordfish")
      refute encoded |> Jason.encode!() |> String.contains?("swordfish")
    end

    test "allowlisted keys stay readable for querying", %{config: config} do
      config = Keyword.put(config, :plaintext_keys, [:status])
      encoded = Codec.encode(%{status: "awaiting_approval", notes: "private"}, config)

      assert encoded |> Jason.encode!() |> String.contains?("awaiting_approval")
      refute encoded |> Jason.encode!() |> String.contains?("private")
      assert Codec.decode(encoded, config) == %{status: "awaiting_approval", notes: "private"}
    end

    test "a rotated key still reads checkpoints sealed with the retired one", %{
      config: config,
      key: old_key
    } do
      sealed = Codec.encode(%{note: "old"}, config)

      rotated =
        config
        |> Keyword.put(:encryption_keys, %{
          "v1" => old_key,
          "v2" => :crypto.strong_rand_bytes(32)
        })
        |> Keyword.put(:encryption_key_id, "v2")

      assert Codec.decode(sealed, rotated) == %{note: "old"}
      assert rotated |> then(&Codec.encode(%{note: "new"}, &1)) |> Codec.decode(rotated)
    end

    test "tampered ciphertext is rejected rather than silently decoded", %{config: config} do
      %{"~m" => [[key, %{"~e" => [key_id, payload]}]]} = Codec.encode(%{note: "real"}, config)
      tampered = %{"~m" => [[key, %{"~e" => [key_id, flip_a_byte(payload)]}]]}

      assert_raise ArgumentError, ~r/failed authentication/, fn ->
        Codec.decode(tampered, config)
      end
    end

    test "a missing key explains why the thread cannot be read", %{config: config} do
      sealed = Codec.encode(%{note: "x"}, config)

      without_key =
        Keyword.put(config, :encryption_keys, %{"other" => :crypto.strong_rand_bytes(32)})

      assert_raise ArgumentError, ~r/no encryption key configured/, fn ->
        Codec.decode(sealed, without_key)
      end
    end

    test "several keys without a designated active one is a configuration error" do
      config = [
        serializer: Encrypted,
        encryption_keys: %{
          "a" => :crypto.strong_rand_bytes(32),
          "b" => :crypto.strong_rand_bytes(32)
        }
      ]

      assert_raise ArgumentError, ~r/:encryption_key_id/, fn ->
        Codec.encode(%{note: "x"}, config)
      end
    end

    test "a wrong-sized key is rejected up front" do
      config = [serializer: Encrypted, encryption_keys: %{"v1" => "too short"}]

      assert_raise ArgumentError, ~r/needs exactly 32/, fn ->
        Codec.encode(%{note: "x"}, config)
      end
    end

    test "omitting keys entirely names the option to set" do
      assert_raise ArgumentError, ~r/:encryption_keys/, fn ->
        Codec.encode(%{note: "x"}, serializer: Encrypted)
      end
    end
  end

  defp flip_a_byte(base64) do
    <<first, rest::binary>> = Base.decode64!(base64)
    Base.encode64(<<Bitwise.bxor(first, 1)>> <> rest)
  end
end
