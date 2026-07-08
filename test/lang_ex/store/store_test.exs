defmodule LangEx.StoreTest do
  use ExUnit.Case, async: false

  alias LangEx.Graph
  alias LangEx.Message
  alias LangEx.Store
  alias LangEx.Tool

  setup do
    Store.ETS.clear()
    :ok
  end

  describe "ETS backend" do
    test "get/put/delete round-trip with rich values" do
      namespace = ["memories", "user-1"]

      assert :ok = Store.ETS.put([], namespace, "profile", %{name: "Ada", tags: [:vip]})
      assert {:ok, %{name: "Ada", tags: [:vip]}} = Store.ETS.get([], namespace, "profile")
      assert :ok = Store.ETS.delete([], namespace, "profile")
      assert :none = Store.ETS.get([], namespace, "profile")
    end

    test "search filters by prefix within a namespace" do
      namespace = ["prefs", "user-1"]
      :ok = Store.ETS.put([], namespace, "diet", "vegan")
      :ok = Store.ETS.put([], namespace, "display_name", "Ada")
      :ok = Store.ETS.put([], namespace, "locale", "en")
      :ok = Store.ETS.put([], ["prefs", "user-2"], "diet", "other")

      assert [{"diet", "vegan"}, {"display_name", "Ada"}] =
               Store.ETS.search([], namespace, prefix: "di")
    end
  end

  describe "store attached to a graph" do
    test "node functions read and write through the convenience API" do
      graph =
        Graph.new(user_id: nil, greeting: nil)
        |> Graph.add_node(:remember, fn state ->
          :ok = Store.put(["memories", state.user_id], "name", "Ada")
          %{}
        end)
        |> Graph.add_node(:recall, fn state ->
          {:ok, name} = Store.get(["memories", state.user_id], "name")
          %{greeting: "Welcome back, #{name}!"}
        end)
        |> Graph.add_edge(:__start__, :remember)
        |> Graph.add_edge(:remember, :recall)
        |> Graph.add_edge(:recall, :__end__)
        |> Graph.compile(store: Store.ETS)

      assert {:ok, %{greeting: "Welcome back, Ada!"}} =
               LangEx.invoke(graph, %{user_id: "u-1"})
    end

    test "memory persists across separate invocations (cross-thread)" do
      graph =
        Graph.new(count: nil)
        |> Graph.add_node(:bump, fn _state ->
          visits = ["stats"] |> Store.get("visits") |> saved_count()
          :ok = Store.put(["stats"], "visits", visits + 1)
          %{count: visits + 1}
        end)
        |> Graph.add_edge(:__start__, :bump)
        |> Graph.add_edge(:bump, :__end__)
        |> Graph.compile(store: Store.ETS)

      {:ok, %{count: 1}} = LangEx.invoke(graph, %{})
      {:ok, %{count: 2}} = LangEx.invoke(graph, %{})
    end

    test "tool functions receive the store in their context" do
      tool = %Tool{
        name: "save_note",
        description: "Persist a note",
        parameters: %{},
        function: fn %{"note" => note}, %{store: {module, config}} ->
          :ok = module.put(config, ["notes"], "latest", note)
          "saved"
        end
      }

      node = LangEx.Tool.Node.node([tool])

      graph =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(:tools, node)
        |> Graph.add_edge(:__start__, :tools)
        |> Graph.add_edge(:tools, :__end__)
        |> Graph.compile(store: Store.ETS)

      call = %Message.ToolCall{name: "save_note", id: "t1", args: %{"note" => "hello"}}
      {:ok, _} = LangEx.invoke(graph, %{messages: [Message.ai(nil, tool_calls: [call])]})

      assert {:ok, "hello"} = Store.ETS.get([], ["notes"], "latest")
    end

    test "without an attached store the convenience API returns an error" do
      graph =
        Graph.new(result: nil)
        |> Graph.add_node(:try_store, fn _state ->
          %{result: Store.get(["x"], "y")}
        end)
        |> Graph.add_edge(:__start__, :try_store)
        |> Graph.add_edge(:try_store, :__end__)
        |> Graph.compile()

      assert {:ok, %{result: {:error, :no_store_attached}}} = LangEx.invoke(graph, %{})
    end
  end

  defp saved_count({:ok, count}), do: count
  defp saved_count(:none), do: 0
end
