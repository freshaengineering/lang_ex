# Send and Fan-Out

When the number of next nodes is known only at runtime (crawl N URLs, score M candidates), return a list of `%LangEx.Send{}` from a conditional edge. Each Send schedules a node with a **custom state payload**.

## Fan-out pattern

```elixir
alias LangEx.Graph
alias LangEx.Send

graph =
  Graph.new(urls: [], summaries: {[], &Kernel.++/2}, report: nil)
  |> Graph.add_node(:plan, fn _ -> %{} end)
  |> Graph.add_node(:crawl, fn state ->
    %{summaries: ["#{state.url}: 200 OK"]}
  end)
  |> Graph.add_node(:report, fn state ->
    %{report: "crawled #{length(state.summaries)} pages"}
  end)
  |> Graph.add_edge(:__start__, :plan)
  |> Graph.add_conditional_edges(:plan, fn state ->
    Enum.map(state.urls, &%Send{node: :crawl, state: %{url: &1}})
  end)
  |> Graph.add_edge(:crawl, :report)
  |> Graph.add_edge(:report, :__end__)
  |> Graph.compile()

{:ok, result} =
  LangEx.invoke(graph, %{urls: ["a.example", "b.example"]},
    max_concurrency: 2,
    node_timeout: 5_000
  )
```

### Struct

```elixir
%LangEx.Send{node: :crawl, state: %{url: "a.example"}}
```

- `:node` — target node atom
- `:state` — map used as that invocation’s view / payload; results merge into shared graph state via reducers

## Concurrency controls

| Invoke option | Role |
|---|---|
| `:max_concurrency` | Cap parallel Send / node tasks (default: online schedulers) |
| `:node_timeout` | Per-task timeout for parallel work |

Use reducers (e.g. list append) for keys written by many workers. Last-write-wins keys race — prefer accumulators for map-reduce outputs.

## Checkpoints

Checkpoint format v2 stores full Send work items. Crash-continue and interrupt-resume restore pending payloads — you do not lose the dynamic fan-out plan.

## Combine with defer

Mark a fan-in node with `defer: true` so it waits until parallel branches finish even when they take different depths:

```elixir
Graph.add_node(g, :aggregate, &aggregate/1, defer: true)
```

Demo: `examples/scripts/03_send_map_reduce.exs`.
