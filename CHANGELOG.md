# Changelog

## v0.11.1

### Checkpoint — resilient atom decoding

- `LangEx.Checkpoint.Serializer.decode/1` no longer crashes when a checkpointed
  **value atom** is not loaded in the current VM. It prefers an existing atom
  and falls back to creating one, so a thread resumes correctly in a fresh VM
  or after a deploy (previously `binary_to_existing_atom` raised
  `ArgumentError`). Module names and struct field keys stay strict — they must
  already exist to rebuild the value, which still bounds atom-table growth from
  structural names.

## v0.11.0

### Middleware — composable agent hooks

- `LangEx.Middleware` — a value-based hook layer for `LangEx.Prebuilt.agent/1`.
  Pass `middleware: [...]` to wrap the model call with `before_model` /
  `after_model` / `wrap_model_call` hooks, contribute tools, and extend the
  agent's state schema — without changing the agent's shape. An `after_model`
  hook can steer routing (loop, go to tools, or end) via the reserved
  `LangEx.Middleware.jump_key/0`.

### ChatModel — state-derived opts

- `LangEx.LLM.ChatModel.node/1` resolves any option given as
  `{:from_state, fn state -> value end}` from the node's state on each call —
  e.g. an `:on_thinking` callback that needs per-run context (channel/thread)
  not known when the graph was built.

### Prebuilt agent — state-derived tools

- `LangEx.Prebuilt.agent/1` accepts `tools: fn state -> [%LangEx.Tool{}] end`
  in addition to a static list. The resolver runs each turn, so tools
  discovered at runtime can be kept as serializable specs in state (and
  materialized on demand) instead of storing executable closures in the
  checkpoint. Middleware-contributed tools are appended to the resolved set.

### Built-in middleware

- `LangEx.Middleware.Summarization` — replaces older history with an
  LLM-written summary once the message list passes `:max_bytes`, persisting
  the summary in place (via `Message.remove_all/0`) so later turns build on it
  rather than resummarising.
- `LangEx.Middleware.ContextEditing` — clears the *contents* of large, stale
  tool results while keeping the message skeleton. No LLM call; idempotent.
- `LangEx.Middleware.TodoList` — a `write_todos` planning tool plus a `:todos`
  state key, keeping long multi-step loops anchored to a plan.
- `LangEx.Middleware.ToolSelector` — a cheap LLM call that narrows a large
  tool set to the relevant subset before the main model call (`:max_tools`,
  `:always_include`); a no-op below the threshold.
- `LangEx.Middleware.Rubric` — an exit gate on the tool loop: scores the
  final answer against a `:rubric` and bounces it back with feedback for
  another pass, up to `:max_attempts`.

### Messages — deletion in the reducer

- `LangEx.Message.remove/1` and `LangEx.Message.remove_all/0` emit
  `%Message.RemoveMessage{}` instructions that `add_messages/2` applies in
  sequence, so a reducer update can prune or replace history, not only append.

### LLM — structured output & completions

- `LangEx.LLM.ChatModel.structured/2` now retries on schema-validation
  failures with the error fed back as feedback (`:max_retries`, default `2`),
  and supports `strategy: :provider` to force the response via the provider's
  native `tool_choice`.
- `LangEx.LLM.ChatModel.complete/2` — one-shot text completion outside a graph
  returning the assistant message with token usage.
- `LangEx.LLM.Anthropic`, `LangEx.LLM.OpenAI`, and `LangEx.LLM.Gemini` accept
  `:tool_choice` (`:auto` / `:required` / `{:tool, name}`), each translated to
  the provider's native forcing mechanism.

### Anthropic — conversation prompt caching

- `LangEx.LLM.Anthropic` marks a rolling `cache_control` breakpoint on the
  last conversation message (in addition to system + last tool), so a long
  agent loop reuses its cached message prefix each turn. Disable with
  `cache_conversation: false`.

### Context compaction

- `LangEx.ContextCompaction.compact_if_needed/2` accepts a `:summarizer`
  (`fn dropped_messages -> String.t()`) to describe dropped rounds with a real
  summary instead of the mechanical tool-name notice.
- Byte accounting now counts AI `tool_calls` args (and tolerates `nil`
  content), so a tool-argument-heavy history triggers compaction correctly
  instead of under-reporting its size.

## v0.10.0

### Embeddings

- `LangEx.Embedding.Hashing.embed/2` — a dependency-free text embedder
  (hashing trick: tokens hashed into fixed-length term-frequency buckets).
  Makes `LangEx.Store` semantic search usable out of the box without a
  neural embedding provider:

      Graph.compile(builder,
        store: {LangEx.Store.ETS, index: [embed: &LangEx.Embedding.Hashing.embed/1]}
      )

  It captures lexical overlap, not meaning; supply a neural embedder when
  semantic similarity matters.

## v0.9.0

### Engine — run budgets & managed values

- New managed value `:is_last_step` injected into node state (LangGraph's
  `IsLastStep`): `true` on the final allowed super-step so a node can
  produce a final answer instead of the engine raising at the recursion
  limit
- `:deadline_ms` invoke option — a wall-clock budget for the whole run.
  Exposes a `:remaining_ms` managed value and flips `:is_last_step` once
  the deadline passes (graceful conclusion, not a raise)
- `:token_budget` invoke option — a cumulative token budget. Exposes a
  `:remaining_tokens` managed value and flips `:is_last_step` when spent;
  usage is read from the `:llm_usage` state key (the `ChatModel.merge_usage/2`
  reducer convention)
- All managed values are stripped before checkpointing and left untouched
  when the user's schema claims the key

### LLM — structured output

- `LangEx.LLM.ChatModel.structured/2` — one-shot, provider-agnostic
  structured extraction outside a graph node. Forces a synthetic `respond`
  tool, decodes the result (falling back to JSON content), and validates
  the schema's top-level `required` keys. Returns `{:ok, map}` or
  `{:error, :no_structured_output | {:missing_required, keys} | term}`
- `LangEx.LLM.ChatModel.validate_structured/2` — reusable required-key
  validation for decoded structured results

### Prebuilt — reflection

- `LangEx.Prebuilt.reflect/1` (and `LangEx.Prebuilt.Reflect.create/1`) — a
  generate → critique → revise loop. A critic evaluates each draft via
  `ChatModel.structured/2` (validated `approved` boolean) and the graph
  loops back to revise until approval or `:max_iterations`

### Store — semantic search

- `LangEx.Store.ETS` supports similarity search via a pluggable embedder
  (`store: {LangEx.Store.ETS, index: [embed: &embed/1]}`). `put/4` embeds
  each value; `search/3` with a `:query` returns entries ranked by cosine
  similarity. Without an embedder, `:query` falls back to prefix ordering

## v0.8.0

### Engine

- Arity-2 node functions now receive `nil` when a run sets no `:context`
  (previously they crashed on a context-less invoke); arity dispatch, not
  context presence, decides the call shape

### LLM

- `LangEx.LLM.ChatModel.structured_node/1` — provider-agnostic structured
  output. The model is given a synthetic `respond` tool whose parameters
  are a JSON-schema; the decoded result is written to an `:into` state key
  and a clean JSON assistant message is appended. Works with any
  tool-calling provider, no per-provider configuration

### Multi-agent

- Tool functions may return a `%LangEx.Command{}` — its `:update` is
  merged into graph state and its `:goto` joins the node's routing.
  `LangEx.Tool.Node` guarantees a `%Message.Tool{}` reply for every call
  (synthesizing one when the command omits it) and keeps returning a
  plain `%{messages_key => [...]}` update when no tool returns a command
  (backwards compatible)
- `LangEx.Prebuilt.Handoff.tool/2` builds a `transfer_to_<agent>` tool
  that moves the conversation to another agent; with
  `task_description: true` the tool also accepts a task brief passed to
  the target agent
- `Swarm.create/1` and `Supervisor.create/1` validate inputs at build
  time (non-empty `:agents`, unique names, valid `:default_active_agent` /
  `:supervisor_name`)
- `LangEx.Prebuilt.Swarm.create/1` — peer-to-peer team where agents hand
  off to one another; the active agent is tracked in `:active_agent` and
  persisted across invocations via the checkpointer
- `LangEx.Prebuilt.Supervisor.create/1` — hub-and-spoke team where a
  supervisor delegates to workers (with a task brief) and workers report
  back. A worker runs on a task-focused view (handoff plumbing stripped)
  and its output is
  reported back as a user-role message attributed to that worker
  (`"Response from the <name> agent: ..."`), so the supervisor can tell
  specialist findings apart from its own reasoning and the conversation
  stays valid for providers that reject a trailing assistant turn.
  Supports `:output_mode` (`:full_history` | `:last_message`)
- `LangEx.Prebuilt.Member` — the routable team-member agent shared by
  both topologies; supports a string or `(state -> string)` callable
  `:system_prompt`, forwards the team's runtime `:context` into each turn,
  and contributes each turn's token usage back under `:llm_usage`
  (teams accumulate usage across turns)
- `:handoff_tool_prefix` on `Swarm.create/1` and `Supervisor.create/1`
  (and `:prefix` on `Handoff.tool/2`) customizes generated handoff tool
  names
- `Member` accepts `:pre_model_hook` (`messages -> messages`) and
  `:post_model_hook` (`update -> update`) for message trimming, extra
  instructions, or guardrails around the LLM call
- `Swarm.create/1` accepts `:add_agent_name` — each agent's replies are
  prefixed with `"[<name>] "` so peers can attribute who said what
- Conflicting state writes from parallel tool calls in one batch keep the
  earliest value and log a warning (a single super-step cannot honour two
  divergent handoffs at once)

## v0.7.0

### Release
- Fix package-scoped Hex publishing pipeline and cut the first published
  release (no library API changes since v0.6.0)

## v0.6.0

### Engine hardening
- Node exceptions surface as `{:error, %LangEx.NodeError{node: ..., reason: ...}}`
  instead of raising out of `invoke/3`/`stream/3`; the original exception and
  failing node are preserved (**breaking**: callers matching on raises must
  match on the error tuple)
- Checkpoint format v2: `next_nodes` and pending-interrupt entries persist
  full work items, so `%LangEx.Send{}` payloads survive crash-continue and
  interrupt-resume (v1 checkpoints still load)
- Completed parallel siblings keep their routing across an interrupt: their
  resolved next targets (and any deferred fan-in backlog) are recorded in the
  interrupt checkpoint and scheduled on resume
- A Send target that interrupts pauses with the shared graph state (its
  payload no longer overwrites the checkpointed state) and resumes with its
  payload intact
- `:node_timeout` applies to single-node super-steps (previously parallel
  super-steps only); timeouts raise `LangEx.NodeTimeoutError` per attempt
- `durability: :exit` writes a final checkpoint on completion and persists
  the failed super-step on error, so `get_state/2` stays truthful and an
  empty re-invoke can retry the failure
- Parallel super-steps emit `node_start`/`node_end` stream events (previously
  single-node super-steps only)
- Dynamic resume answers survive static breakpoints: `resume_values` persist
  through breakpoint checkpoints, and the resumed super-step bypasses
  breakpoints that already fired

### Validation
- `add_node/4` rejects duplicate and reserved (`:__start__`/`:__end__`)
  names, and validates option values; `:cache` cannot combine with `:on_error`
- `add_edge/3` rejects edges from `:__end__`; `add_conditional_edges/4`
  rejects a second routing function for the same source
- `compile/2` validates `interrupt_before`/`interrupt_after` node names
- Routing to an undefined node (Command goto / Send) raises a descriptive
  `ArgumentError` naming the known nodes

### Persistence
- New `LangEx.Checkpointer.Memory` — built-in ETS backend for development
  and tests
- Postgres checkpointer stores `next_nodes`/`pending_interrupts` as proper
  jsonb payloads (previously unusable due to an array/jsonb type mismatch)
  and breaks `created_at` ordering ties by step and checkpoint id
- Subgraphs with their own checkpointer resume interrupts from their
  namespaced checkpoint instead of re-running from `:__start__`
- `LangEx.Interrupt.interrupt/1` raises a clear error when called outside a
  graph node process (e.g. from tool functions)

### Streaming
- Stream modes: `modes: [:updates, :values, :messages, :custom]` on `LangEx.stream/3`
- Token deltas from streaming LLM adapters surface as `{:message_delta, ...}` events
  (`:on_token` callback on the Anthropic adapter)
- `LangEx.Graph.Stream.emit/1` to publish custom events from inside nodes
- `stream/3` accepts `%Command{resume: ...}` and crash-continue (`%{}`) inputs
- Interrupts are emitted as `{:interrupt, payload}` stream events

### Execution policies
- Per-node options on `Graph.add_node/4`: `retry:` (capped exponential
  backoff with jitter and `retryable?` — see `LangEx.Graph.RetryPolicy`;
  `backoff_ms` accepted as a legacy alias for `initial_interval_ms`),
  `cache:` (ETS memoization with TTL), `defer:` (fan-in barrier),
  `timeout:` (per-attempt budget, retryable), `on_error:` (fallback handler
  after retries are exhausted; its return value becomes the node result)
- Node cache verifies the stored input on lookup (hash collisions miss
  instead of serving wrong results), deletes expired entries on read, and is
  size-bounded via the `:node_cache_max_entries` application env
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
