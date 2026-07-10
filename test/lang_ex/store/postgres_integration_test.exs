defmodule LangEx.Store.PostgresIntegrationTest do
  # Requires a running Postgres (docker-compose.yml) — run with:
  #   mix test --include integration
  use ExUnit.Case, async: false

  @moduletag :integration

  alias LangEx.IntegrationRepo
  alias LangEx.Store.Postgres

  setup_all do
    :ok = LangEx.Integration.start_repo!()
    :ok = LangEx.Integration.migrate!()
    :ok
  end

  defp config, do: [repo: IntegrationRepo]

  defp namespace(label), do: ["store-int", "#{label}-#{System.unique_integer([:positive])}"]

  test "put/get round-trips rich terms" do
    ns = namespace("roundtrip")
    :ok = Postgres.put(config(), ns, "prefs", %{diet: :vegan, scores: [{:q1, 5}]})

    assert {:ok, %{diet: :vegan, scores: [{:q1, 5}]}} = Postgres.get(config(), ns, "prefs")
  end

  test "put upserts existing keys" do
    ns = namespace("upsert")
    :ok = Postgres.put(config(), ns, "k", 1)
    :ok = Postgres.put(config(), ns, "k", 2)

    assert {:ok, 2} = Postgres.get(config(), ns, "k")
  end

  test "get returns :none for missing keys and delete removes" do
    ns = namespace("delete")
    :ok = Postgres.put(config(), ns, "k", :v)
    :ok = Postgres.delete(config(), ns, "k")

    assert Postgres.get(config(), ns, "k") == :none
    assert Postgres.get(config(), ns, "never-there") == :none
  end

  test "search filters by prefix, sorts by key, and escapes LIKE wildcards" do
    ns = namespace("search")
    :ok = Postgres.put(config(), ns, "user:b", 2)
    :ok = Postgres.put(config(), ns, "user:a", 1)
    :ok = Postgres.put(config(), ns, "other", 3)
    :ok = Postgres.put(config(), ns, "100%_done", 4)

    assert [{"user:a", 1}, {"user:b", 2}] = Postgres.search(config(), ns, prefix: "user:")
    assert [{"100%_done", 4}] = Postgres.search(config(), ns, prefix: "100%")
    assert Postgres.search(config(), ns, prefix: "user:", limit: 1) == [{"user:a", 1}]
  end
end
