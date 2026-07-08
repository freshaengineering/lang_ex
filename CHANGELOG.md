# Changelog

## v0.6.0 (unreleased)

### Streaming
- Stream modes: `modes: [:updates, :values, :messages, :custom]` on `LangEx.stream/3`
- Token deltas from streaming LLM adapters surface as `{:message_delta, ...}` events
  (`:on_token` callback on the Anthropic adapter)
- `LangEx.Graph.Stream.emit/1` to publish custom events from inside nodes
- `stream/3` accepts `%Command{resume: ...}` and crash-continue (`%{}`) inputs
- Interrupts are emitted as `{:interrupt, payload}` stream events

### Execution policies
- Per-node options on `Graph.add_node/4`: `retry:` (backoff + `retryable?`),
  `cache:` (ETS memoization with TTL), `defer:` (fan-in barrier)
- `ChatModel.node(resilient: ...)` routes calls through `LLM.Resilient`
- `:durability` invoke option: `:sync` | `:async` | `:exit` checkpoint writes

### Prebuilts
- `LangEx.Prebuilt.agent/1` — one-call tool-loop agent with system prompt,
  usage accounting, and context compaction wired in

### Long-term memory
- `LangEx.Store` behaviour with ETS and Postgres backends; attach with
  `Graph.compile(store: ...)`; reachable in nodes and tools via
  `LangEx.Store.get/put/delete/search`
- Migration V2 (`lang_ex_store` table + checkpoint `version` column)

### Checkpointer operations
- `delete_thread/1` on the behaviour, both backends, and the facade
  (`LangEx.delete_thread/2`)
- `Checkpointer.Postgres.prune/2` retention window (`older_than:`)
- Checkpoint format `version` field persisted with every checkpoint
- Redis backend surfaces errors instead of swallowing them into `[]`/`:none`

### Graphs
- Compile-time validation of conditional-edge mapping targets; warning for
  unreachable nodes (`warn_unreachable: false` to silence)
- `Graph.to_mermaid/1` flowchart export
- `%Command{goto: {:parent, target}}` routes the parent graph from inside a
  subgraph (bubbles one level per graph boundary)
- A schema-declared `:remaining_steps` key is no longer overwritten by the
  managed value

## v0.5.0

- Durable execution: crashed runs resume from checkpointed pending nodes
- Lossless checkpoint serialization (`LangEx.Checkpoint.Serializer`)
- State APIs: `get_state/2`, `get_state_history/2`, `update_state/3`,
  `parent_id` lineage, load by `checkpoint_id`
- Interrupts v2: stable IDs, multiple interrupts per node, id-addressed
  resume maps, static breakpoints (`interrupt_before` / `interrupt_after`),
  parallel-step interrupt safety
- Subgraph propagation: interrupts, errors, context, stream events, and
  namespaced checkpoint config flow through compiled-graph nodes
- Run-tree telemetry (`run_id` / `parent_run_id`), named graphs, and an
  optional OpenTelemetry bridge
- Token usage accounting in `ChatModel` (`chat_with_usage`, `merge_usage/2`)
- Bounded concurrency: `max_concurrency` / `node_timeout` invoke options and
  `Tool.Node` `max_concurrency` / `timeout`
- Streaming rework: supervised runner, no inactivity halt, crash surfacing
- Send fan-out results merge through reducers and follow target edges

## v0.1.0

Initial release.

- StateGraph builder with nodes, edges, conditional routing, and `add_sequence`
- Pregel super-step execution engine with parallel node execution via `Task.Supervisor`
- State reducers (per-key merge functions)
- Command routing (combined state update + control flow)
- Checkpointing (Redis via Redix, PostgreSQL via Ecto)
- Oban-style versioned Postgres migrations (`LangEx.Migration`)
- Interrupts / human-in-the-loop (`LangEx.Interrupt`)
- Streaming (`LangEx.Stream` via `Stream.resource`)
- Runtime context injection (arity-2 node functions)
- Subgraph support (compiled graphs as nodes)
- Send fan-out for dynamic map-reduce patterns
- Managed values (`remaining_steps`)
- ChatModels registry with model-string auto-resolution
- Built-in LLM adapters: OpenAI, Anthropic
- MessagesState convenience schema
- Message types: Human, AI, System, Tool
