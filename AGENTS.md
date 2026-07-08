# LangEx

Graph-based agent orchestration for Elixir. Builds stateful, multi-step LLM workflows using nodes, edges, conditional routing, state reducers, human-in-the-loop interrupts, and checkpointing. Inspired by LangGraph, built on BEAM primitives.

- **Version**: 0.6.0, **Elixir**: ~> 1.16
- **Deps**: `req`, `jason`, `telemetry`; optional `redix`, `postgrex`, `ecto_sql`, `opentelemetry_api`, `opentelemetry_telemetry`
- **Test**: ExUnit with `mimic` for mocking

## Commands

```bash
mix deps.get                          # Install dependencies
mix compile --warnings-as-errors      # Compile (0 warnings required)
mix test                              # Run all tests (integration excluded)
mix test --include integration        # Also run Redis/Postgres tests (needs docker compose up)
mix test path/to/test.exs:42          # Run specific test
mix format                            # Auto-format
mix format --check-formatted          # Check formatting
```

Integration tests read `LANG_EX_REDIS_URL` / `LANG_EX_POSTGRES_URL`
(defaults match `docker-compose.yml`).

Always run `mix compile --warnings-as-errors` before considering work done. Zero warnings required.

## Architecture

```
LangEx (facade: invoke/3, stream/3, get_state/2, get_state_history/2, update_state/3, delete_thread/2)
├── Graph                             # Builder: new, add_node (+retry/cache/defer/timeout/on_error), add_edge, compile, to_mermaid
│   ├── Graph.Compiled                # Compiled executable graph
│   ├── Graph.Pregel                  # Super-step execution engine (internal)
│   ├── Graph.RetryPolicy             # Exponential backoff + jitter for retry: nodes
│   ├── Graph.State                   # State management with reducers
│   ├── Graph.NodeCache               # Bounded ETS memoization for cache: nodes
│   └── Graph.Stream                  # Lazy event streaming with modes + emit/1
├── NodeError / NodeTimeoutError      # Structured node failure contract ({:error, %NodeError{}})
├── LLM                               # Behaviour for provider adapters
│   ├── LLM.Anthropic                 # Claude adapter (streaming SSE)
│   │   ├── Anthropic.SSE             # SSE state machine (internal)
│   │   └── Anthropic.Formatter       # Message wire format (internal)
│   ├── LLM.OpenAI                    # GPT adapter
│   ├── LLM.Gemini                    # Gemini adapter
│   ├── LLM.Resilient                 # Retry wrapper with backoff
│   ├── LLM.ChatModel                 # Graph node helper for LLM calls
│   └── LLM.Registry                  # Provider resolution by model string
├── Tool                              # Tool/function definition struct
│   ├── Tool.Node                     # Graph node for parallel tool execution
│   └── Tool.Annotation               # Error recovery guidance for LLM
├── Message                           # Chat message types (Human, AI, System, Tool)
├── Checkpoint / Checkpointer         # Pause/resume with Memory, Redis, or Postgres
├── Store                             # Long-term memory (ETS / Postgres backends)
├── Migration                         # Versioned Postgres migrations (V1, V2)
├── Prebuilt                          # Ready-made agent graph constructor
├── Command / Send / Interrupt        # Graph control flow primitives
├── Config                            # Layered config resolution
├── ContextCompaction                 # Context window budget enforcement
└── Telemetry                         # Telemetry event definitions (+ Runs, OTel bridge)
```

### Behaviours

| Behaviour | Callbacks | Purpose |
|-----------|-----------|---------|
| `LangEx.LLM` | `chat/2`, `chat_with_usage/2` (optional) | LLM provider adapters |
| `LangEx.Checkpointer` | `save/2`, `load/1`, `list/2`, `delete_thread/1` | Checkpoint persistence backends |
| `LangEx.Store` | `get/3`, `put/4`, `delete/3`, `search/3` | Long-term memory backends |

### Key Design Decisions

- **No GenServers for domain state** -- graph state lives in function arguments and checkpoints, not processes
- **Pregel execution model** -- discrete super-steps with parallel node execution via `Task.Supervisor`
- **Process dictionary for interrupts** -- resume values are keyed by stable interrupt IDs (`"node:index"`) and delivered through the process dictionary per node execution
- **Reducers for state merging** -- each state key can have a custom reducer `(old, new) -> merged`
- **Structured error contract** -- node exceptions surface as `{:error, %LangEx.NodeError{}}` after retries; programmer errors (undefined routing targets, invalid builder input) raise
- **Checkpoints hold full work entries** -- `next_nodes` persists node atoms *and* `%Send{}` structs (format v2), so payloads survive crash-continue and interrupt-resume; interrupt checkpoints also carry completed siblings' resolved targets (`metadata.completed_next`)

## Module Hierarchy

```
lib/lang_ex.ex                        → LangEx (facade)
lib/lang_ex/
├── application.ex                    → LangEx.Application (supervisor + ETS tables)
├── command.ex                        → LangEx.Command
├── config.ex                        → LangEx.Config
├── context_compaction.ex            → LangEx.ContextCompaction
├── interrupt.ex                     → LangEx.Interrupt
├── node_error.ex                    → LangEx.NodeError (exception)
├── node_timeout_error.ex            → LangEx.NodeTimeoutError (exception)
├── prebuilt.ex                      → LangEx.Prebuilt
├── send.ex                          → LangEx.Send
├── telemetry.ex                     → LangEx.Telemetry
├── telemetry/
│   ├── runs.ex                      → LangEx.Telemetry.Runs (run-tree correlation)
│   └── open_telemetry_bridge.ex     → LangEx.Telemetry.OpenTelemetryBridge (optional)
├── checkpoint/
│   ├── checkpoint.ex                → LangEx.Checkpoint
│   ├── checkpointer.ex             → LangEx.Checkpointer (behaviour)
│   ├── serializer.ex                → LangEx.Checkpoint.Serializer
│   ├── memory.ex                    → LangEx.Checkpointer.Memory
│   ├── postgres.ex                  → LangEx.Checkpointer.Postgres
│   ├── postgres/schema.ex           → LangEx.Checkpointer.Postgres.Schema (@moduledoc false)
│   ├── postgres/jsonb_list.ex       → LangEx.Checkpointer.Postgres.JsonbList (@moduledoc false)
│   └── redis.ex                     → LangEx.Checkpointer.Redis
├── graph/
│   ├── graph.ex                     → LangEx.Graph
│   ├── compiled_graph.ex            → LangEx.Graph.Compiled
│   ├── pregel.ex                    → LangEx.Graph.Pregel (internal engine)
│   ├── retry_policy.ex              → LangEx.Graph.RetryPolicy
│   ├── node_cache.ex                → LangEx.Graph.NodeCache
│   ├── state.ex                     → LangEx.Graph.State
│   └── stream.ex                    → LangEx.Graph.Stream
├── llm/
│   ├── llm.ex                       → LangEx.LLM (behaviour)
│   ├── anthropic.ex                 → LangEx.LLM.Anthropic
│   ├── anthropic/sse.ex             → LangEx.LLM.Anthropic.SSE (@moduledoc false)
│   ├── anthropic/formatter.ex       → LangEx.LLM.Anthropic.Formatter (@moduledoc false)
│   ├── openai.ex                    → LangEx.LLM.OpenAI
│   ├── gemini.ex                    → LangEx.LLM.Gemini
│   ├── resilient.ex                 → LangEx.LLM.Resilient
│   ├── chat_model.ex                → LangEx.LLM.ChatModel
│   └── chat_models.ex               → LangEx.LLM.Registry
├── message/
│   ├── message.ex                   → LangEx.Message (+ nested structs)
│   └── messages_state.ex            → LangEx.MessagesState
├── migration/
│   ├── migration.ex                 → LangEx.Migration
│   ├── v1.ex                        → LangEx.Migration.V1 (@moduledoc false)
│   └── v2.ex                        → LangEx.Migration.V2 (@moduledoc false)
├── store/
│   ├── store.ex                     → LangEx.Store (behaviour + attached API)
│   ├── ets.ex                       → LangEx.Store.ETS
│   ├── postgres.ex                  → LangEx.Store.Postgres
│   └── postgres/schema.ex           → LangEx.Store.Postgres.Schema (@moduledoc false)
└── tool/
    ├── tool.ex                      → LangEx.Tool
    ├── node.ex                      → LangEx.Tool.Node
    └── annotation.ex                → LangEx.Tool.Annotation
```

## Code Style

Non-negotiable. Every change must follow these rules.

### Never Do

- `if` or `else` in function bodies
- `case`/`cond` when function heads with pattern matching work
- Nesting deeper than 1 level inside a function body
- Grouped aliases: `alias Foo.{Bar, Baz}`
- `alias Foo.Bar, as: Baz`
- Section divider comments: `# --- Section ---`
- `maybe_`, `do_`, `_if_`, `_or_` in function names
- Declaring a variable to use it exactly once
- `Enum.reduce` when `Enum.map |> Enum.sum` expresses intent better
- Missing `@spec` on public functions
- Missing `@moduledoc` on modules

### Always Do

- Pattern match in function heads for dispatch
- Guard clauses (`when`) for type/value checks
- Single-expression function bodies (one pipeline or `with`)
- Pipe operator for data transformation chains
- `with` for chaining fallible operations
- One alias per line, alphabetical
- Module names that mirror directory paths
- Test directory structure that mirrors lib
- Inline mock setup in every test via `Mimic.expect/3` or `Mimic.stub/3`
- Pattern-matching assertions: `assert %Message.AI{content: "hello"} = msg`

### Module Organization

Inside each module, order declarations as:

1. `@moduledoc`
2. `use` / `import` / `require`
3. `alias` (alphabetical)
4. Module attributes (`@constants`)
5. Types and struct
6. Public functions (with `@doc`, `@spec`)
7. Private functions

## Gotchas

- **Optional deps are compile-time guarded**: the Postgres modules (`checkpoint/postgres*.ex`, `store/postgres*.ex`, `migration/v*.ex`) and `checkpoint/redis.ex` are wrapped in `if Code.ensure_loaded?(Ecto)` / `if Code.ensure_loaded?(Redix)`. New optional-dep modules must follow the same pattern.
- **Process dictionary is used intentionally** in `Graph.Pregel` (interrupt/resume via `:lang_ex_current_node`, `:lang_ex_interrupt_counter`, `:lang_ex_resume_values`; run correlation via `:lang_ex_run_id`) and `LLM.Anthropic` (SSE streaming state). This is not a code smell here — it's the mechanism for cross-cutting concerns within a single execution.
- **`Mimic.copy` in `test/test_helper.exs`** must be updated when adding new modules that tests need to mock.
- **Ask before refactoring** beyond the immediate task. Style and structure changes require explicit approval.

## Workflow

### Adding New Modules

- Place the file where its module name dictates: `LangEx.Foo.Bar` -> `lib/lang_ex/foo/bar.ex`
- Add a corresponding test at `test/lang_ex/foo/bar_test.exs`
- If a directory gains 2+ related files, group them in a subdirectory
- Internal modules get `@moduledoc false`

### Adding New LLM Providers

1. Create `lib/lang_ex/llm/provider_name.ex` implementing `@behaviour LangEx.LLM`
2. Implement `chat/2` (required) and optionally `chat_with_usage/2`
3. Register in `LangEx.LLM.Registry` with prefix patterns
4. Add tests at `test/lang_ex/llm/provider_name_test.exs` using `Mimic.stub/3`

### Adding New Checkpointers

1. Create module implementing `@behaviour LangEx.Checkpointer`
2. Implement `save/2`, `load/1`, `list/2`, `delete_thread/1`
3. Wrap in `if Code.ensure_loaded?(Dep)` for optional dependencies
4. Preserve `next_nodes` entries losslessly — they contain `%Send{}` structs, not just atoms (use `LangEx.Checkpoint.Serializer`)
