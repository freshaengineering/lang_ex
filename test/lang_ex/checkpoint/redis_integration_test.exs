defmodule LangEx.Checkpointer.RedisIntegrationTest do
  # Requires a running Redis (docker-compose.yml) — run with:
  #   mix test --include integration
  use ExUnit.Case, async: false

  @moduletag :integration

  alias LangEx.Checkpoint
  alias LangEx.Checkpointer.Redis
  alias LangEx.Graph
  alias LangEx.Message
  alias LangEx.Send

  setup_all do
    {:ok, conn} = Redix.start_link(LangEx.Integration.redis_url())
    %{conn: conn}
  end

  defp config(conn, thread_id), do: [conn: conn, thread_id: thread_id]

  defp thread_id(label), do: "redis-int-#{label}-#{System.unique_integer([:positive])}"

  defp checkpoint(thread_id, attrs) do
    Checkpoint.new(Keyword.merge([thread_id: thread_id, metadata: %{}], attrs))
  end

  describe "checkpoint round-trips" do
    test "state with structs, Send entries, and interrupts survives exactly", %{conn: conn} do
      thread = thread_id("roundtrip")

      saved =
        checkpoint(thread,
          state: %{messages: [Message.human("hi", id: "m1")], count: {:tally, 3}},
          next_nodes: [:agent, %Send{node: :worker, state: %{item: "a"}}],
          step: 2,
          pending_interrupts: [
            %{
              id: "worker:0",
              value: "ok?",
              node: :worker,
              entry: %Send{node: :worker, state: %{item: "a"}}
            }
          ],
          metadata: %{resume_values: %{"worker:0" => true}, completed_next: [:agent]}
        )

      :ok = Redis.save(config(conn, thread), saved)

      assert {:ok,
              %Checkpoint{
                state: %{messages: [%Message.Human{content: "hi"}], count: {:tally, 3}},
                next_nodes: [:agent, %Send{node: :worker, state: %{item: "a"}}],
                step: 2,
                pending_interrupts: [%{id: "worker:0", entry: %Send{}}],
                metadata: %{resume_values: %{"worker:0" => true}, completed_next: [:agent]}
              }} = Redis.load(config(conn, thread))
    end

    test "load by checkpoint_id and :none for unknown ids", %{conn: conn} do
      thread = thread_id("by-id")
      first = checkpoint(thread, state: %{v: 1}, next_nodes: [:a], step: 0)
      :ok = Redis.save(config(conn, thread), first)

      :ok =
        Redis.save(
          config(conn, thread),
          checkpoint(thread, state: %{v: 2}, next_nodes: [:b], step: 1)
        )

      assert {:ok, %Checkpoint{state: %{v: 1}}} =
               Redis.load(config(conn, thread) ++ [checkpoint_id: first.checkpoint_id])

      assert Redis.load(config(conn, thread) ++ [checkpoint_id: "missing"]) == :none
      assert Redis.load(config(conn, thread_id("unknown"))) == :none
    end

    test "list returns most recent first and honors :limit", %{conn: conn} do
      thread = thread_id("list")

      Enum.each(0..4, fn step ->
        :ok =
          Redis.save(
            config(conn, thread),
            checkpoint(thread, state: %{}, next_nodes: [], step: step)
          )

        Process.sleep(2)
      end)

      assert [%Checkpoint{step: 4}, %Checkpoint{step: 3}] =
               Redis.list(config(conn, thread), limit: 2)
    end

    test "delete_thread removes checkpoints and the index", %{conn: conn} do
      thread = thread_id("delete")

      :ok =
        Redis.save(config(conn, thread), checkpoint(thread, state: %{}, next_nodes: [], step: 0))

      :ok = Redis.delete_thread(config(conn, thread))

      assert Redis.load(config(conn, thread)) == :none
      assert Redis.list(config(conn, thread)) == []
    end

    test "the :ttl config sets expiry on keys", %{conn: conn} do
      thread = thread_id("ttl")

      :ok =
        Redis.save(
          config(conn, thread) ++ [ttl: 120],
          checkpoint(thread, state: %{}, next_nodes: [], step: 0)
        )

      {:ok, ttl} = Redix.command(conn, ["TTL", "lang_ex:thread:#{thread}"])
      assert ttl > 0 and ttl <= 120
    end
  end

  describe "end-to-end graph flow" do
    test "interrupt and resume with a Send payload through Redis", %{conn: conn} do
      graph =
        Graph.new(results: {[], &Kernel.++/2})
        |> Graph.add_node(:setup, fn _state -> %{} end)
        |> Graph.add_node(:worker, fn state ->
          answer = LangEx.Interrupt.interrupt("process #{state.item}?")
          %{results: [{state.item, answer}]}
        end)
        |> Graph.add_edge(:__start__, :setup)
        |> Graph.add_conditional_edges(:setup, fn _state ->
          [%Send{node: :worker, state: %{item: "a"}}]
        end)
        |> Graph.add_edge(:worker, :__end__)
        |> Graph.compile(checkpointer: Redis)

      thread = thread_id("e2e")
      cfg = config(conn, thread)

      {:interrupt, "process a?", _} = LangEx.invoke(graph, %{}, config: cfg)

      {:ok, result} = LangEx.invoke(graph, %LangEx.Command{resume: :yes}, config: cfg)

      assert %{results: [{"a", :yes}]} = result
    end
  end
end
