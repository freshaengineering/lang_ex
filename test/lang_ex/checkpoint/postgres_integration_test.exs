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
                checkpoint_ns: "",
                source: :step,
                version: 3
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

    test "prune scoped to one thread leaves other threads alone" do
      doomed = thread_id("prune-scoped")
      kept = thread_id("prune-untouched")
      old = DateTime.add(DateTime.utc_now(), -90, :day)

      Enum.each([doomed, kept], fn thread ->
        :ok =
          Postgres.save(
            config(thread),
            %Checkpoint{checkpoint(thread, state: %{}, next_nodes: [], step: 0) | created_at: old}
          )
      end)

      cutoff = DateTime.add(DateTime.utc_now(), -30, :day)
      {:ok, 1} = Postgres.prune(config(doomed), older_than: cutoff)

      assert Postgres.load(config(doomed)) == :none
      assert {:ok, _} = Postgres.load(config(kept))
    end

    test "prune keeps the most recent checkpoints so a thread stays resumable" do
      thread = thread_id("prune-keep")
      old = DateTime.add(DateTime.utc_now(), -90, :day)

      Enum.each(0..3, fn step ->
        :ok =
          Postgres.save(
            config(thread),
            %Checkpoint{
              checkpoint(thread, state: %{v: step}, next_nodes: [], step: step)
              | created_at: DateTime.add(old, step, :second)
            }
          )
      end)

      cutoff = DateTime.add(DateTime.utc_now(), -30, :day)
      {:ok, 2} = Postgres.prune(config(thread), older_than: cutoff, keep_latest: 2)

      assert [%Checkpoint{step: 3}, %Checkpoint{step: 2}] = Postgres.list(config(thread))
    end
  end

  describe "namespaces" do
    test "subgraph checkpoints share the thread and are separated by namespace" do
      thread = thread_id("ns")
      root = config(thread)
      nested = config(thread) ++ [checkpoint_ns: "planner"]

      :ok = Postgres.save(root, checkpoint(thread, state: %{v: :root}, next_nodes: [], step: 0))

      :ok =
        Postgres.save(
          nested,
          checkpoint(thread,
            state: %{v: :nested},
            next_nodes: [],
            step: 0,
            checkpoint_ns: "planner"
          )
        )

      assert {:ok, %Checkpoint{state: %{v: :root}}} = Postgres.load(root)
      assert {:ok, %Checkpoint{state: %{v: :nested}}} = Postgres.load(nested)
      assert [_one] = Postgres.list(root)
    end

    test "delete_thread removes every namespace of the thread" do
      thread = thread_id("ns-del")
      nested = config(thread) ++ [checkpoint_ns: "planner"]

      :ok = Postgres.save(config(thread), checkpoint(thread, state: %{}, next_nodes: [], step: 0))

      :ok =
        Postgres.save(
          nested,
          checkpoint(thread, state: %{}, next_nodes: [], step: 0, checkpoint_ns: "planner")
        )

      :ok = Postgres.delete_thread(config(thread))

      assert Postgres.load(config(thread)) == :none
      assert Postgres.load(nested) == :none
    end
  end

  describe "history pagination and provenance" do
    test "the :before cursor pages backwards and :source filters" do
      thread = thread_id("page")

      Enum.each(0..4, fn step ->
        :ok =
          Postgres.save(
            config(thread),
            checkpoint(thread,
              state: %{v: step},
              next_nodes: [],
              step: step,
              source: source_for(step)
            )
          )
      end)

      [newest | rest] = Postgres.list(config(thread))
      page = Postgres.list(config(thread), before: newest.checkpoint_id, limit: 2)

      assert Enum.map(page, & &1.step) == rest |> Enum.take(2) |> Enum.map(& &1.step)

      assert [%Checkpoint{source: :input, step: 0}] =
               Postgres.list(config(thread), source: :input)
    end

    test "an unknown :before cursor is rejected" do
      thread = thread_id("page-bad")
      :ok = Postgres.save(config(thread), checkpoint(thread, state: %{}, next_nodes: [], step: 0))

      assert_raise ArgumentError, ~r/not a checkpoint/, fn ->
        Postgres.list(config(thread), before: "missing")
      end
    end

    defp source_for(0), do: :input
    defp source_for(_step), do: :step
  end

  describe "copy_thread/2" do
    test "the copy carries every namespace and stays independent" do
      source = thread_id("copy-src")
      target = thread_id("copy-dst")
      nested = config(source) ++ [checkpoint_ns: "planner"]

      :ok = Postgres.save(config(source), checkpoint(source, state: %{v: 1}, step: 0))

      :ok =
        Postgres.save(
          nested,
          checkpoint(source, state: %{v: 2}, step: 0, checkpoint_ns: "planner")
        )

      :ok = Postgres.copy_thread(config(source), target)
      :ok = Postgres.save(config(target), checkpoint(target, state: %{v: 99}, step: 1))

      assert {:ok, %Checkpoint{state: %{v: 99}}} = Postgres.load(config(target))
      assert {:ok, %Checkpoint{state: %{v: 1}}} = Postgres.load(config(source))

      assert {:ok, %Checkpoint{thread_id: ^target, state: %{v: 2}}} =
               Postgres.load(config(target) ++ [checkpoint_ns: "planner"])
    end
  end

  describe "write journal" do
    test "journaled work is readable until the anchor's checkpoint lands" do
      thread = thread_id("journal")
      cfg = config(thread)
      write = %{task_id: "worker#abc", node: :worker, update: %{done: [:a]}, idx: 3}

      :ok = Postgres.put_writes(cfg, "anchor-1:3", write, [])

      assert [%{task_id: "worker#abc", node: :worker, update: %{done: [:a]}, idx: 3}] =
               Postgres.load_writes(cfg, "anchor-1:3")

      assert [] = Postgres.load_writes(cfg, "other-anchor:3")

      :ok = Postgres.discard_writes(cfg, "anchor-1:3")
      assert [] = Postgres.load_writes(cfg, "anchor-1:3")
    end

    test "re-journaling the same task replaces rather than duplicates" do
      thread = thread_id("journal-idem")
      cfg = config(thread)
      write = %{task_id: "worker#abc", node: :worker, update: %{v: 1}, idx: 0}

      :ok = Postgres.put_writes(cfg, "a:0", write, [])
      :ok = Postgres.put_writes(cfg, "a:0", %{write | update: %{v: 2}}, [])

      assert [%{update: %{v: 2}}] = Postgres.load_writes(cfg, "a:0")
    end

    test "a crashed super-step recovers without re-running completed nodes" do
      test_pid = self()

      graph =
        Graph.new(done: {[], &Kernel.++/2})
        |> Graph.add_node(:enter, fn _state -> %{} end)
        |> Graph.add_node(:slow, fn _state ->
          send(test_pid, :slow_ran)
          %{done: [:slow]}
        end)
        |> Graph.add_node(:boom, fn _state -> crash_once() end)
        |> Graph.add_edge(:__start__, :enter)
        |> Graph.add_edge(:enter, :slow)
        |> Graph.add_edge(:enter, :boom)
        |> Graph.add_edge(:slow, :__end__)
        |> Graph.add_edge(:boom, :__end__)
        |> Graph.compile(checkpointer: Postgres, warn_unreachable: false)

      cfg = config(thread_id("journal-e2e"))

      assert {:error, _} = LangEx.invoke(graph, %{}, config: cfg)
      assert_received :slow_ran

      assert {:ok, %{done: done}} = LangEx.invoke(graph, %{}, config: cfg)
      assert Enum.sort(done) == [:boom, :slow]
      refute_received :slow_ran
    end

    defp crash_once do
      key = {__MODULE__, :crash_once}

      case :persistent_term.get(key, :pending) do
        :pending ->
          :persistent_term.put(key, :done)
          raise "boom"

        :done ->
          :persistent_term.erase(key)
          %{done: [:boom]}
      end
    end
  end

  describe "encryption at rest" do
    import Ecto.Query

    test "state is unreadable in the row but round-trips through the codec" do
      thread = thread_id("encrypted")

      cfg =
        config(thread) ++
          [
            serializer: LangEx.Checkpoint.Codec.Encrypted,
            encryption_keys: %{"v1" => :crypto.strong_rand_bytes(32)},
            plaintext_keys: [:status]
          ]

      :ok =
        Postgres.save(
          cfg,
          checkpoint(thread,
            state: %{
              messages: [Message.human("my private notes", id: "m1")],
              status: "awaiting_approval"
            },
            next_nodes: [],
            step: 0
          )
        )

      raw =
        LangEx.Checkpointer.Postgres.Schema
        |> where([c], c.thread_id == ^thread)
        |> select([c], c.state)
        |> IntegrationRepo.one()
        |> Jason.encode!()

      refute String.contains?(raw, "my private notes")
      assert String.contains?(raw, "awaiting_approval")

      assert {:ok,
              %Checkpoint{
                state: %{
                  messages: [%Message.Human{content: "my private notes"}],
                  status: "awaiting_approval"
                }
              }} = Postgres.load(cfg)
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

  describe "blob dedup" do
    import Ecto.Query

    test "a large unchanged value is stored once per thread and round-trips" do
      thread = thread_id("blob")
      big = String.duplicate("t", 40_000)

      for step <- 0..2 do
        :ok =
          Postgres.save(
            config(thread),
            checkpoint(thread, state: %{tool_specs: big, step: step}, step: step)
          )
      end

      blob_rows =
        LangEx.Checkpointer.Postgres.BlobSchema
        |> where([b], b.thread_id == ^thread)
        |> IntegrationRepo.all()

      assert length(blob_rows) == 1

      assert {:ok, %Checkpoint{state: %{tool_specs: ^big, step: 2}}} =
               Postgres.load(config(thread))

      assert [%Checkpoint{state: %{tool_specs: ^big}} | _] =
               Postgres.list(config(thread))
    end

    test "delete_thread removes the thread's blobs" do
      thread = thread_id("blob-del")
      big = String.duplicate("d", 40_000)

      :ok = Postgres.save(config(thread), checkpoint(thread, state: %{tool_specs: big}, step: 0))
      :ok = Postgres.delete_thread(config(thread))

      assert [] =
               LangEx.Checkpointer.Postgres.BlobSchema
               |> where([b], b.thread_id == ^thread)
               |> IntegrationRepo.all()
    end

    test "blob_threshold: :infinity stores everything inline" do
      thread = thread_id("blob-inline")
      big = String.duplicate("i", 40_000)
      cfg = config(thread) ++ [blob_threshold: :infinity]

      :ok = Postgres.save(cfg, checkpoint(thread, state: %{tool_specs: big}, step: 0))

      assert [] =
               LangEx.Checkpointer.Postgres.BlobSchema
               |> where([b], b.thread_id == ^thread)
               |> IntegrationRepo.all()

      assert {:ok, %Checkpoint{state: %{tool_specs: ^big}}} = Postgres.load(cfg)
    end
  end
end
