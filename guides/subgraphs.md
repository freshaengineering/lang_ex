# Subgraphs

Any **compiled** graph can be added as a node inside another graph. Use this to nest workflows (intake → specialist → synthesize) without flattening everything into one mega-graph.

## Nesting a compiled graph

```elixir
alias LangEx.Graph

inner =
  Graph.new(value: 0)
  |> Graph.add_node(:double, fn s -> %{value: s.value * 2} end)
  |> Graph.add_edge(:__start__, :double)
  |> Graph.add_edge(:double, :__end__)
  |> Graph.compile()

outer =
  Graph.new(value: 0, label: "")
  |> Graph.add_node(:sub, inner)
  |> Graph.add_node(:tag, fn _ -> %{label: "done"} end)
  |> Graph.add_edge(:__start__, :sub)
  |> Graph.add_edge(:sub, :tag)
  |> Graph.add_edge(:tag, :__end__)
  |> Graph.compile()
```

What propagates across the boundary:

- **State updates** from the subgraph merge into the parent via parent reducers
- **Runtime context**
- **Stream events**
- **Errors** (`NodeError` surfaces out of the outer invoke)
- **Interrupts** — with caveats below

## Interrupt + checkpoint behaviour

| Inner checkpointer? | On resume |
|---|---|
| **Yes** | Checkpoints are namespaced under `"{thread_id}/{node_name}"`. The subgraph resumes from its saved position; nodes before the interrupt do **not** re-run. |
| **No** | The subgraph re-runs from `:__start__` with resume values injected. Pre-interrupt inner nodes execute again — keep their side effects idempotent. |

```elixir
inner =
  Graph.new(...)
  |> ...
  |> Graph.compile(checkpointer: LangEx.Checkpointer.Redis)

outer =
  Graph.new(...)
  |> Graph.add_node(:specialist, inner)
  |> ...
  |> Graph.compile(checkpointer: LangEx.Checkpointer.Redis)
```

Give both levels a checkpointer when nested interrupts must be durable and cheap to resume.

## Design tips

- Prefer subgraphs when a unit is **reused** or owned by another team/module.
- Keep the outer graph as the **orchestrator** (route, approve, summarize).
- Match schemas thoughtfully — shared keys with compatible reducers avoid surprises.

Demo: `examples/scripts/09_subgraphs.exs`.
