# Observability

LangEx emits structured `:telemetry` events for graph runs, super-steps, nodes, LLM calls, and checkpoints. Spans form a **run tree** you can reconstruct end-to-end.

## Run-tree correlation

Every span’s metadata includes:

| Key | Description |
|---|---|
| `:run_id` | Unique id of this span |
| `:parent_run_id` | Enclosing span (`nil` at root) |

Typical tree:

```
graph.invoke
├── graph.step
│   ├── node.execute (:agent)
│   │   └── llm.chat
│   └── node.execute (:tools)
└── checkpoint.save
```

Subgraph invokes appear as child invoke spans under the parent node. Helpers: `LangEx.Telemetry.Runs`.

## Event catalog (summary)

| Event prefix | When |
|---|---|
| `[:lang_ex, :graph, :invoke, …]` | Whole invoke (start / stop / exception) |
| `[:lang_ex, :graph, :step, …]` | Each Pregel super-step |
| `[:lang_ex, :node, :execute, …]` | Individual node |
| `[:lang_ex, :llm, :chat, …]` | Provider call (+ optional `:usage`) |
| Checkpoint events | Save / load paths |

Stop metadata for invoke includes `:result` ∈ `:ok | :interrupt | :error`. Full field tables live in `LangEx.Telemetry`’s moduledoc.

## Attach a handler

```elixir
:telemetry.attach_many(
  "lang-ex-logger",
  [
    [:lang_ex, :graph, :invoke, :stop],
    [:lang_ex, :llm, :chat, :stop],
    [:lang_ex, :node, :execute, :exception]
  ],
  &MyApp.Telemetry.handle_event/4,
  nil
)
```

## OpenTelemetry

Optional bridge when you depend on OpenTelemetry packages:

```elixir
{:opentelemetry_api, "~> 1.2"},
{:opentelemetry_telemetry, "~> 1.1"}
```

See `LangEx.Telemetry.OpenTelemetryBridge` for attaching OTel export.

## Demo

```bash
elixir examples/scripts/10_observability.exs
```

Rebuilds a run tree from `run_id` / `parent_run_id` in-process — a good template for dashboards.
