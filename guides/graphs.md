# Graphs

A LangEx graph is a **builder** (`LangEx.Graph`) that becomes an immutable **compiled** runner (`LangEx.Graph.Compiled`). You only invoke compiled graphs.

## Building a graph

```elixir
alias LangEx.Graph

builder =
  Graph.new(value: 0)
  |> Graph.add_node(:inc, fn state -> %{value: state.value + 1} end)
  |> Graph.add_edge(:__start__, :inc)
  |> Graph.add_edge(:inc, :__end__)

graph = Graph.compile(builder)
```

Pipeline order is idiomatic Elixir: `new → add_node* → add_edge* → compile`.

### Special nodes

| Name | Role |
|---|---|
| `:__start__` | Implicit entry; always wire at least one edge from here |
| `:__end__` | Implicit exit; reaching it finishes the run |

You cannot register nodes with those names — they are reserved.

## Nodes

A node is a function that receives the current state and returns an **update**:

```elixir
# Arity 1 — state only
Graph.add_node(g, :greet, fn state ->
  %{reply: "hi #{state.name}"}
end)

# Arity 2 — state + runtime context (see Configuration / Runtime Context)
Graph.add_node(g, :greet, fn _state, context ->
  %{reply: "hi from #{context.tenant}"}
end)
```

Return shapes:

| Return | Effect |
|---|---|
| `%{key => value}` | Merge into state via reducers |
| `%LangEx.Command{update: ..., goto: ...}` | Update state **and** override next hop |
| Raising | Retried per policy, then `{:error, %LangEx.NodeError{}}` |

A **compiled graph** can itself be a node — see [Subgraphs](subgraphs.md).

### Execution policies

`add_node/4` accepts policies that apply per node:

```elixir
Graph.add_node(g, :fetch, &fetch/1,
  timeout: 10_000,
  retry: [max_attempts: 4, initial_interval_ms: 200, backoff_factor: 2.0, jitter: true],
  on_error: fn exception, _state -> %{failed: Exception.message(exception)} end,
  cache: [ttl: 60_000],
  defer: true
)
```

| Option | Purpose |
|---|---|
| `:retry` | Exponential backoff on **exceptions** (not `{:error, _}` tuples) |
| `:timeout` | Per-attempt budget; timeout raises `LangEx.NodeTimeoutError` |
| `:on_error` | Fallback after retries; return value becomes the node result |
| `:cache` | Memoize success by input state (bounded ETS) |
| `:defer` | Fan-in barrier: wait until no other non-deferred nodes are active |

Full detail: [Errors and Policies](errors_and_policies.md).

## Edges

### Static edges

```elixir
Graph.add_edge(g, :a, :b)
Graph.add_edge(g, :b, :__end__)
```

Multiple outgoing static edges from one node schedule **parallel** next nodes in the same super-step family (subject to the Pregel scheduler). Prefer a single static edge or a conditional when you want exclusive branching.

### Conditional edges

```elixir
Graph.add_conditional_edges(g, :classify, &Map.get(&1, :intent), %{
  "weather" => :weather,
  "greeting" => :greet
})
```

The routing function receives state and returns a key looked up in the path map. Missing keys raise (programmer error). The routing function may also return:

- a **list** of targets — multiple next nodes
- a list of `%LangEx.Send{}` — dynamic fan-out ([Send and Fan-Out](send_and_fanout.md))

## Compile options

```elixir
Graph.compile(builder,
  name: :support_agent,
  checkpointer: LangEx.Checkpointer.Redis,
  store: LangEx.Store.ETS,
  interrupt_before: [:charge],
  interrupt_after: [:tools]
)
```

| Option | Purpose |
|---|---|
| `:name` | Telemetry / debugging identity |
| `:checkpointer` | Persistence backend (required for resume / interrupts that survive) |
| `:store` | Long-term memory attached for the run |
| `:interrupt_before` / `:interrupt_after` | Static breakpoints on named nodes |

## Invoke and stream

```elixir
# Run to completion (or interrupt / error)
{:ok, state} = LangEx.invoke(graph, %{messages: [...]},
  config: [thread_id: "t-1"],
  context: %{tenant: "acme"},
  recursion_limit: 25,
  max_concurrency: 8,
  durability: :sync
)

# Lazy event stream
graph
|> LangEx.stream(%{messages: [...]})
|> Enum.each(&IO.inspect/1)
```

### Invoke options (high-signal)

| Option | Default | Notes |
|---|---|---|
| `:config` | `[]` | Must include `:thread_id` when using a checkpointer |
| `:context` | — | Passed to arity-2 nodes; `nil` if omitted |
| `:recursion_limit` | `25` | Max super-steps before raising |
| `:max_concurrency` | schedulers | Cap parallel node / `Send` tasks |
| `:node_timeout` | `:infinity` | Timeout for parallel tasks |
| `:durability` | `:sync` | Checkpoint write mode — see [Checkpointing](checkpointing.md) |

### Continue vs restart

With a checkpointer:

- **Non-empty input** — start a new pass from `:__start__`, merging into latest checkpointed state.
- **Empty input `%{}`** — continue unfinished work from the last checkpoint’s pending nodes (crash recovery).
- **`%LangEx.Command{resume: …}`** — resume after an interrupt.

## Visualization

```elixir
Graph.to_mermaid(builder)
# => "graph TD; ..."
```

Useful for README diagrams and design reviews.

## Design tips

- Prefer **small nodes** with one job (classify, fetch, decide, speak).
- Put **side effects after interrupts**, or make them idempotent — interrupted nodes re-run from the top on resume.
- Keep routing functions **pure** and cheap; expensive IO belongs in nodes.
- Use `Command` when a node must both update state and choose the next hop.
