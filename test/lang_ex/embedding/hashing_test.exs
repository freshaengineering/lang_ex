defmodule LangEx.Embedding.HashingTest do
  use ExUnit.Case, async: true

  alias LangEx.Embedding.Hashing
  alias LangEx.Graph
  alias LangEx.Store

  describe "embed/2" do
    test "produces a fixed-length vector" do
      assert length(Hashing.embed("hello world", dims: 64)) == 64
      assert length(Hashing.embed("hello world")) == 256
    end

    test "is deterministic" do
      assert Hashing.embed("database connection pool") ==
               Hashing.embed("database connection pool")
    end

    test "counts token frequency into buckets" do
      vector = Hashing.embed("retry retry retry", dims: 32)
      assert Enum.sum(vector) == 3.0
    end

    test "empty text yields a zero vector" do
      assert Hashing.embed("", dims: 16) == List.duplicate(0.0, 16)
    end

    test "shared tokens raise cosine similarity above disjoint text" do
      dims = 128
      query = Hashing.embed("database connection pool exhausted", dims: dims)
      near = Hashing.embed("the database connection pool is exhausted", dims: dims)
      far = Hashing.embed("cpu throttling on the node", dims: dims)

      assert cosine(query, near) > cosine(query, far)
    end
  end

  describe "as a Store embedder" do
    setup do
      Store.ETS.clear()
      :ok
    end

    test "ranks entries by lexical similarity to the query" do
      config = [index: [embed: &Hashing.embed/1]]
      namespace = ["incidents"]

      :ok = Store.ETS.put(config, namespace, "a", "database connection pool exhausted")
      :ok = Store.ETS.put(config, namespace, "b", "kubernetes pod eviction loop")

      assert [{"a", _} | _] =
               Store.ETS.search(config, namespace,
                 query: "database connection pool saturated",
                 limit: 2
               )
    end

    test "works as a graph store embedder end to end" do
      graph =
        Graph.new(hit: nil)
        |> Graph.add_node(:remember, fn _state ->
          :ok = Store.put(["notes"], "n1", "kafka consumer lag spike")
          :ok = Store.put(["notes"], "n2", "s3 upload latency")
          %{}
        end)
        |> Graph.add_node(:recall, fn _state ->
          [{key, _value} | _] = Store.search(["notes"], query: "consumer lag on kafka", limit: 1)
          %{hit: key}
        end)
        |> Graph.add_edge(:__start__, :remember)
        |> Graph.add_edge(:remember, :recall)
        |> Graph.add_edge(:recall, :__end__)
        |> Graph.compile(store: {Store.ETS, index: [embed: &Hashing.embed/1]})

      assert {:ok, %{hit: "n1"}} = LangEx.invoke(graph, %{})
    end
  end

  defp cosine(a, b) do
    dot = a |> Enum.zip(b) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()
    dot / (magnitude(a) * magnitude(b))
  end

  defp magnitude(vector), do: vector |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
end
