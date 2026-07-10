defmodule LangEx.Graph.NodeCacheTest do
  use ExUnit.Case, async: false

  alias LangEx.Graph.NodeCache

  setup do
    NodeCache.clear()
    on_exit(fn -> Application.delete_env(:lang_ex, :node_cache_max_entries) end)
    :ok
  end

  describe "collision safety" do
    test "an entry under the same key with a different input misses" do
      NodeCache.store({:node, 123}, {:fun_ref, %{query: "a"}}, :result_a, :infinity)

      assert NodeCache.fetch({:node, 123}, {:fun_ref, %{query: "a"}}) == {:ok, :result_a}
      assert NodeCache.fetch({:node, 123}, {:fun_ref, %{query: "b"}}) == :miss
    end
  end

  describe "expiry" do
    test "expired entries miss and are deleted on read" do
      NodeCache.store(:key, :input, :result, 10)
      Process.sleep(20)

      assert NodeCache.fetch(:key, :input) == :miss
      assert :ets.lookup(:lang_ex_node_cache, :key) == []
    end

    test "infinite ttl entries never expire" do
      NodeCache.store(:key, :input, :result, :infinity)
      assert NodeCache.fetch(:key, :input) == {:ok, :result}
    end
  end

  describe "bounded size" do
    test "the table never grows past the configured maximum" do
      Application.put_env(:lang_ex, :node_cache_max_entries, 5)

      Enum.each(1..20, &NodeCache.store({:key, &1}, {:input, &1}, {:result, &1}, :infinity))

      assert :ets.info(:lang_ex_node_cache, :size) <= 5
    end

    test "expired entries are purged before flushing live ones" do
      Application.put_env(:lang_ex, :node_cache_max_entries, 3)

      NodeCache.store(:expired_a, :input, :result, 1)
      NodeCache.store(:expired_b, :input, :result, 1)
      Process.sleep(10)
      NodeCache.store(:live, :input, :result, :infinity)

      # The next insert hits capacity; purging the expired entries makes
      # room without dropping the live one.
      NodeCache.store(:new, :input, :result, :infinity)

      assert NodeCache.fetch(:live, :input) == {:ok, :result}
      assert NodeCache.fetch(:new, :input) == {:ok, :result}
    end
  end
end
