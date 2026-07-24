defmodule LangEx.Checkpointer.Postgres.BlobsTest do
  use ExUnit.Case, async: true

  alias LangEx.Checkpoint.Serializer
  alias LangEx.Checkpointer.Postgres.Blobs

  describe "split/2" do
    test "extracts values above the threshold and leaves small ones inline" do
      big = String.duplicate("x", 200)
      encoded = Serializer.encode(%{tools: big, count: 7})

      {slim, blobs} = Blobs.split(encoded, 100)

      assert map_size(blobs) == 1
      [{hash, stored}] = Map.to_list(blobs)
      assert stored == big

      assert %{"~m" => pairs} = slim
      assert [Serializer.encode(:tools), %{"~blob" => hash}] in pairs
      assert [Serializer.encode(:count), 7] in pairs
    end

    test "identical values produce the same hash (content-addressed)" do
      big = String.duplicate("y", 200)

      {_slim1, blobs1} = Blobs.split(Serializer.encode(%{a: big}), 100)
      {_slim2, blobs2} = Blobs.split(Serializer.encode(%{b: big}), 100)

      assert Map.keys(blobs1) == Map.keys(blobs2)
    end

    test ":infinity threshold stores everything inline" do
      encoded = Serializer.encode(%{tools: String.duplicate("x", 100_000)})

      assert {^encoded, blobs} = Blobs.split(encoded, :infinity)
      assert blobs == %{}
    end

    test "non-map-encoded state passes through untouched" do
      assert {42, %{}} = Blobs.split(42, 100)
    end
  end

  describe "resolve/2" do
    test "round-trips a split state exactly" do
      state = %{tools: String.duplicate("z", 300), step: 3, tags: [:a, :b]}
      encoded = Serializer.encode(state)

      {slim, blobs} = Blobs.split(encoded, 100)

      restored = Blobs.resolve(slim, fn hashes -> Map.take(blobs, hashes) end)

      assert Serializer.decode(restored) == state
    end

    test "a state without markers never calls fetch" do
      encoded = Serializer.encode(%{small: "value"})

      assert Blobs.resolve(encoded, fn _ -> flunk("fetch called") end) == encoded
    end

    test "a missing blob raises instead of silently corrupting state" do
      {slim, _blobs} = Blobs.split(Serializer.encode(%{big: String.duplicate("q", 200)}), 100)

      assert_raise ArgumentError, ~r/missing blob/, fn ->
        Blobs.resolve(slim, fn _hashes -> %{} end)
      end
    end
  end
end
