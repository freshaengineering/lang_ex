defmodule LangEx.Features.NodePoliciesTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Graph
  alias LangEx.Graph.NodeCache
  alias LangEx.LLM.ChatModel
  alias LangEx.Message

  setup do
    NodeCache.clear()
    :ok
  end

  describe "retry: node option" do
    test "retries a failing node until it succeeds" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      graph =
        Graph.new(value: nil)
        |> Graph.add_node(
          :flaky,
          fn _state ->
            Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
            |> Kernel.<(3)
            |> fail_below_three()
          end,
          retry: [max_attempts: 3, backoff_ms: 1]
        )
        |> Graph.add_edge(:__start__, :flaky)
        |> Graph.add_edge(:flaky, :__end__)
        |> Graph.compile()

      assert {:ok, %{value: :recovered}} = LangEx.invoke(graph, %{})
      assert Agent.get(attempts, & &1) == 3
    end

    test "exhausted retries reraise the original exception" do
      graph =
        Graph.new(value: nil)
        |> Graph.add_node(:doomed, fn _state -> raise "always fails" end,
          retry: [max_attempts: 2, backoff_ms: 1]
        )
        |> Graph.add_edge(:__start__, :doomed)
        |> Graph.add_edge(:doomed, :__end__)
        |> Graph.compile()

      assert_raise RuntimeError, "always fails", fn -> LangEx.invoke(graph, %{}) end
    end

    test "retryable?: false errors are not retried" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      graph =
        Graph.new(value: nil)
        |> Graph.add_node(
          :strict,
          fn _state ->
            Agent.update(attempts, &(&1 + 1))
            raise ArgumentError, "bad input"
          end,
          retry: [max_attempts: 5, backoff_ms: 1, retryable?: &match?(%RuntimeError{}, &1)]
        )
        |> Graph.add_edge(:__start__, :strict)
        |> Graph.add_edge(:strict, :__end__)
        |> Graph.compile()

      assert_raise ArgumentError, fn -> LangEx.invoke(graph, %{}) end
      assert Agent.get(attempts, & &1) == 1
    end
  end

  describe "cache: node option" do
    test "identical input state serves the cached result" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      graph =
        Graph.new(query: nil, result: nil)
        |> Graph.add_node(
          :expensive,
          fn state ->
            Agent.update(calls, &(&1 + 1))
            %{result: "computed:#{state.query}"}
          end,
          cache: true
        )
        |> Graph.add_edge(:__start__, :expensive)
        |> Graph.add_edge(:expensive, :__end__)
        |> Graph.compile()

      {:ok, %{result: "computed:a"}} = LangEx.invoke(graph, %{query: "a"})
      {:ok, %{result: "computed:a"}} = LangEx.invoke(graph, %{query: "a"})
      {:ok, %{result: "computed:b"}} = LangEx.invoke(graph, %{query: "b"})

      assert Agent.get(calls, & &1) == 2
    end

    test "expired ttl recomputes" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      graph =
        Graph.new(result: nil)
        |> Graph.add_node(
          :cached,
          fn _state ->
            Agent.update(calls, &(&1 + 1))
            %{result: :ok}
          end,
          cache: [ttl: 20]
        )
        |> Graph.add_edge(:__start__, :cached)
        |> Graph.add_edge(:cached, :__end__)
        |> Graph.compile()

      {:ok, _} = LangEx.invoke(graph, %{})
      Process.sleep(30)
      {:ok, _} = LangEx.invoke(graph, %{})

      assert Agent.get(calls, & &1) == 2
    end
  end

  describe "defer: node option" do
    test "deferred fan-in node runs once, after all branches" do
      {:ok, joins} = Agent.start_link(fn -> 0 end)

      graph =
        Graph.new(hits: {[], &Kernel.++/2}, summary: nil)
        |> Graph.add_node(:fan, fn _state -> %{} end)
        |> Graph.add_node(:short, fn _state -> %{hits: [:short]} end)
        |> Graph.add_node(:long_a, fn _state -> %{hits: [:long_a]} end)
        |> Graph.add_node(:long_b, fn _state -> %{hits: [:long_b]} end)
        |> Graph.add_node(
          :join,
          fn state ->
            Agent.update(joins, &(&1 + 1))
            %{summary: state.hits |> Enum.sort() |> Enum.join(",")}
          end,
          defer: true
        )
        |> Graph.add_edge(:__start__, :fan)
        |> Graph.add_edge(:fan, :short)
        |> Graph.add_edge(:fan, :long_a)
        |> Graph.add_edge(:long_a, :long_b)
        |> Graph.add_edge(:short, :join)
        |> Graph.add_edge(:long_b, :join)
        |> Graph.add_edge(:join, :__end__)
        |> Graph.compile()

      # :short reaches :join one step before :long_b; without defer the
      # join would run twice with partial state.
      assert {:ok, %{summary: "long_a,long_b,short"}} = LangEx.invoke(graph, %{})
      assert Agent.get(joins, & &1) == 1
    end
  end

  describe "unknown node options" do
    test "raise at build time" do
      assert_raise ArgumentError, ~r/unknown node option/, fn ->
        Graph.new(value: 0)
        |> Graph.add_node(:bad, fn state -> state end, retyr: true)
      end
    end
  end

  describe "resilient: option on ChatModel" do
    test "retries transient provider failures through Resilient" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
        |> Kernel.==(1)
        |> rate_limited_then_ok()
      end)

      graph =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(
          :llm,
          ChatModel.node(
            provider: LangEx.LLM.OpenAI,
            model: "gpt-4o",
            resilient: [max_retries: 2, retry_base_ms: 1]
          )
        )
        |> Graph.add_edge(:__start__, :llm)
        |> Graph.add_edge(:llm, :__end__)
        |> Graph.compile()

      {:ok, result} = LangEx.invoke(graph, %{messages: [Message.human("Hi")]})

      assert %{messages: [_, %Message.AI{content: "recovered"}]} = result
      assert Agent.get(calls, & &1) == 2
    end
  end

  defp fail_below_three(true), do: raise("transient")
  defp fail_below_three(false), do: %{value: :recovered}

  defp rate_limited_then_ok(true), do: {:error, {429, %{}}}

  defp rate_limited_then_ok(false),
    do: {:ok, Message.ai("recovered"), %{input_tokens: 1, output_tokens: 1}}
end
