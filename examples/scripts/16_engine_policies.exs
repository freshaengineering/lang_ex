# Execution policy: scoped barriers, ephemeral keys, graph-wide defaults.
#
# Four knobs that shape *when* and *how often* a node runs, rather than
# what it computes:
#
#   defer: [:a, :b]     a fan-in barrier that waits for its own branches
#   ephemeral: [:key]   state that survives one step and never reaches storage
#   node_defaults:      retry/timeout policy for every node at once
#   cache: [key: fun]   memoize on what the node actually reads
#
# Run: elixir examples/scripts/16_engine_policies.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])
Code.require_file("support/in_memory_checkpointer.exs", __DIR__)

# The retried node below fails on purpose, and a failing node logs a crash
# report before the retry policy recovers it. Muting the logger keeps this
# script's output readable; leave it on in a real system.
Logger.configure(level: :none)

defmodule ResearchDemo do
  alias Example.InMemoryCheckpointer
  alias LangEx.Graph

  def run do
    graph = build()
    config = [thread_id: "research-1"]

    {:ok, result} = LangEx.invoke(graph, %{query: "wombat diet"}, config: config)
    first_run_attempts = counter(:flaky_attempts)

    IO.puts("run order: #{Enum.join(result.trace, " -> ")}")
    IO.puts("report:    #{result.report}")

    # :merge released as soon as its own two branches were done, while the
    # audit chain was still running. `defer: true` would have queued it
    # behind every active node, unrelated audit included.
    IO.puts("\nmerge ran before the audit chain finished: #{merged_early?(result.trace)}")

    # The routing hint was readable by the step after the one that wrote
    # it, has reset by the end of the run, and never reached the
    # checkpoint — so a later turn cannot act on a stale signal, and the
    # signal is not sitting in storage waiting to be leaked.
    IO.puts("hint seen by the next step: #{inspect(result.hint_seen)}")
    IO.puts("hint left in final state:   #{inspect(result.route_hint)}")
    IO.puts("hint in the checkpoint:     #{inspect(persisted_hint(graph, config))}")

    # :flaky raises once and recovers. It carries no options of its own —
    # the graph-wide default retry policy covers it.
    IO.puts("\nflaky node attempts: #{first_run_attempts}")

    # :embed is expensive and only reads the query. A second thread with
    # an unrelated field added still hits the cache; a new query misses.
    {:ok, _} =
      LangEx.invoke(graph, %{query: "wombat diet", requester: "ada"}, config: thread("2"))

    {:ok, _} = LangEx.invoke(graph, %{query: "quokka diet"}, config: thread("3"))

    IO.puts("embed calls over 3 runs of 2 distinct queries: #{counter(:embed_calls)}")
  end

  defp build do
    Graph.new(
      [
        query: nil,
        requester: nil,
        route_hint: nil,
        hint_seen: nil,
        facts: {[], &Kernel.++/2},
        report: nil,
        trace: {[], &Kernel.++/2}
      ],
      # A signal, not data: readable once, then reset, never checkpointed.
      ephemeral: [:route_hint]
    )
    |> Graph.add_node(:plan, &plan/1)
    |> Graph.add_node(:search, &search/1)
    |> Graph.add_node(:embed, &embed/1, cache: [key: & &1.query])
    |> Graph.add_node(:enrich, &enrich/1)
    # Waits for its own branches — not for the audit chain beside them.
    |> Graph.add_node(:merge, &merge/1, defer: [:search, :embed, :enrich])
    |> Graph.add_node(:audit_open, &trace(&1, :audit_open))
    |> Graph.add_node(:flaky, &flaky/1)
    |> Graph.add_node(:audit_close, &trace(&1, :audit_close))
    |> Graph.add_edge(:__start__, :plan)
    |> Graph.add_edge(:plan, :search)
    |> Graph.add_edge(:plan, :enrich)
    |> Graph.add_edge(:plan, :audit_open)
    |> Graph.add_edge(:search, :embed)
    |> Graph.add_edge(:embed, :merge)
    |> Graph.add_edge(:enrich, :merge)
    |> Graph.add_edge(:audit_open, :flaky)
    |> Graph.add_edge(:flaky, :audit_close)
    |> Graph.add_edge(:merge, :__end__)
    |> Graph.add_edge(:audit_close, :__end__)
    |> Graph.compile(
      name: :research,
      checkpointer: InMemoryCheckpointer,
      # Retries and a time budget for every node, without repeating the
      # policy at each call site.
      node_defaults: [retry: [max_attempts: 3, initial_interval_ms: 1], timeout: 5_000]
    )
  end

  defp plan(_state), do: %{route_hint: :deep, trace: [:plan]}

  # Written by :plan, still readable here, gone by the end of the run.
  defp search(state),
    do: %{facts: ["wombats eat grass"], hint_seen: state.route_hint, trace: [:search]}

  defp enrich(_state), do: %{facts: ["wombats are nocturnal"], trace: [:enrich]}

  defp merge(state), do: %{report: Enum.join(state.facts, "; "), trace: [:merge]}

  defp trace(_state, name), do: %{trace: [name]}

  defp embed(state) do
    bump(:embed_calls)
    %{facts: ["embedded: #{state.query}"], trace: [:embed]}
  end

  defp flaky(_state) do
    bump(:flaky_attempts)
    :flaky_attempts |> counter() |> crash_first_attempt()
    %{trace: [:flaky]}
  end

  defp crash_first_attempt(1), do: raise("index temporarily locked")
  defp crash_first_attempt(_later), do: :ok

  defp merged_early?(trace) do
    Enum.find_index(trace, &(&1 == :merge)) < Enum.find_index(trace, &(&1 == :audit_close))
  end

  defp persisted_hint(graph, config) do
    {:ok, checkpoint} = LangEx.get_state(graph, config: config)
    Map.get(checkpoint.state, :route_hint, :absent)
  end

  defp thread(suffix), do: [thread_id: "research-#{suffix}"]

  defp bump(counter), do: :persistent_term.put(counter, counter(counter) + 1)
  defp counter(counter), do: :persistent_term.get(counter, 0)
end

ResearchDemo.run()
