defmodule LangEx.Checkpointer.PostgresIntegrationTest do
  # Requires a running Postgres (docker-compose.yml) — run with:
  #   mix test --include integration
  use ExUnit.Case, async: false

  @moduletag :integration

  alias LangEx.Checkpoint
  alias LangEx.Checkpointer.Postgres
  alias LangEx.Graph
  alias LangEx.IntegrationRepo
  alias LangEx.Message
  alias LangEx.Send

  setup_all do
    :ok = LangEx.Integration.start_repo!()
    :ok = LangEx.Integration.migrate!()
    :ok
  end

  defp config(thread_id), do: [repo: IntegrationRepo, thread_id: thread_id]

  defp thread_id(label), do: "pg-int-#{label}-#{System.unique_integer([:positive])}"

  defp checkpoint(thread_id, attrs) do
    Checkpoint.new(Keyword.merge([thread_id: thread_id, metadata: %{}], attrs))
  end

  describe "checkpoint round-trips" do
    test "state with structs, Send entries, and interrupts survives exactly" do
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

      :ok = Postgres.save(config(thread), saved)

      assert {:ok,
              %Checkpoint{
                state: %{messages: [%Message.Human{content: "hi"}], count: {:tally, 3}},
                next_nodes: [:agent, %Send{node: :worker, state: %{item: "a"}}],
                step: 2,
                pending_interrupts: [%{id: "worker:0", entry: %Send{}}],
                metadata: %{resume_values: %{"worker:0" => true}, completed_next: [:agent]},
                version: 2
              }} = Postgres.load(config(thread))
    end

    test "saving the same checkpoint_id twice upserts" do
      thread = thread_id("upsert")
      first = checkpoint(thread, state: %{v: 1}, next_nodes: [:a], step: 0)
      :ok = Postgres.save(config(thread), first)
      :ok = Postgres.save(config(thread), %Checkpoint{first | state: %{v: 2}})

      assert {:ok, %Checkpoint{state: %{v: 2}}} = Postgres.load(config(thread))
      assert [_only_one] = Postgres.list(config(thread))
    end

    test "load prefers the higher step when created_at ties" do
      thread = thread_id("tiebreak")
      created_at = DateTime.utc_now()

      Enum.each([0, 1], fn step ->
        :ok =
          Postgres.save(
            config(thread),
            %Checkpoint{
              checkpoint(thread, state: %{step: step}, next_nodes: [], step: step)
              | created_at: created_at
            }
          )
      end)

      assert {:ok, %Checkpoint{step: 1}} = Postgres.load(config(thread))
      assert [%Checkpoint{step: 1}, %Checkpoint{step: 0}] = Postgres.list(config(thread))
    end

    test "delete_thread removes only that thread" do
      doomed = thread_id("doomed")
      kept = thread_id("kept")
      :ok = Postgres.save(config(doomed), checkpoint(doomed, state: %{}, next_nodes: [], step: 0))
      :ok = Postgres.save(config(kept), checkpoint(kept, state: %{}, next_nodes: [], step: 0))

      :ok = Postgres.delete_thread(config(doomed))

      assert Postgres.load(config(doomed)) == :none
      assert {:ok, _} = Postgres.load(config(kept))
    end

    test "prune deletes checkpoints older than the cutoff" do
      thread = thread_id("prune")
      old = DateTime.add(DateTime.utc_now(), -90, :day)

      :ok =
        Postgres.save(
          config(thread),
          %Checkpoint{checkpoint(thread, state: %{}, next_nodes: [], step: 0) | created_at: old}
        )

      :ok = Postgres.save(config(thread), checkpoint(thread, state: %{}, next_nodes: [], step: 1))

      cutoff = DateTime.add(DateTime.utc_now(), -30, :day)
      {:ok, deleted} = Postgres.prune([repo: IntegrationRepo], older_than: cutoff)

      assert deleted >= 1
      assert [%Checkpoint{step: 1}] = Postgres.list(config(thread))
    end
  end

  describe "end-to-end graph flow" do
    test "interrupt and resume with a Send payload through Postgres" do
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
        |> Graph.compile(checkpointer: Postgres)

      cfg = config(thread_id("e2e"))

      {:interrupt, "process a?", _} = LangEx.invoke(graph, %{}, config: cfg)

      {:ok, result} = LangEx.invoke(graph, %LangEx.Command{resume: :yes}, config: cfg)

      assert %{results: [{"a", :yes}]} = result
    end
  end
end
