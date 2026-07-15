# Introduction

LangEx is a **graph-based agent orchestration** library for Elixir. You model LLM workflows as directed graphs: nodes transform state, edges decide what runs next, and a compiled runner executes the whole thing with checkpointing, streaming, and human-in-the-loop pauses.

It is inspired by [LangGraph](https://www.langchain.com/langgraph), reimplemented on BEAM primitives — processes, supervisors, streams, and telemetry — instead of threads and async runtimes.

## What you get

| Capability | Why it matters |
|---|---|
| **State graphs** | Explicit control flow: classify → retrieve → answer, not a single opaque prompt |
| **Conditional routing** | Branch on intent, tool calls, or any pure function of state |
| **Parallel super-steps** | Fan-out with `Send`, run siblings concurrently under `Task.Supervisor` |
| **Checkpointing** | Pause, crash-recover, and time-travel with Memory, Redis, or Postgres |
| **Interrupts** | Human approval mid-run; resume hours later with the same `thread_id` |
| **Streaming** | Lazy Elixir `Stream` of execution events for LiveView, channels, SSE |
| **Pluggable LLMs** | Anthropic, OpenAI, Gemini out of the box; register your own provider |
| **Prebuilt agents** | Tool-calling loops, swarms, and supervisor teams in a few lines |

## Mental model

```
Input state
    │
    ▼
┌─────────────┐     edges /      ┌─────────────┐
│   Node A    │───conditionals──▶│   Node B    │──▶ …
└─────────────┘                  └─────────────┘
    │                                  │
    └──────── state updates merge via reducers ──┘
                      │
                      ▼
              Checkpoint (optional)
                      │
                      ▼
              {:ok, final_state}
           or {:interrupt, payload, state}
           or {:error, %LangEx.NodeError{}}
```

1. **Define a schema** — which keys exist and how updates merge (reducers).
2. **Add nodes** — functions `(state -> update)` or `(state, context -> update)`.
3. **Wire edges** — static (`:a → :b`) or conditional (`routing_fn → path map`).
4. **Compile** — validate, freeze, optionally attach a checkpointer / store.
5. **Invoke or stream** — run to completion, pause on interrupt, or consume events.

## Why Elixir?

Agent workflows are long-lived, concurrent, and failure-prone. The BEAM is already designed for that:

- **Thousands of threads are cheap** — graph state lives in arguments and checkpoints, not GenServers per conversation.
- **Parallelism without async soup** — `Task.Supervisor` fans out tool calls and `Send` branches with backpressure (`max_concurrency`).
- **Streaming is a first-class type** — pipe `LangEx.stream/3` into Phoenix.
- **Supervisors isolate failure** — one bad agent run does not take down the VM.

## When to use LangEx

**Use it when** you need multi-step LLM workflows with branching, tools, durability, or human approval — support triage, incident response, research agents, approval gates, multi-agent handoffs.

**Skip it when** a single `chat/2` call is enough. Use `LangEx.LLM` adapters directly if you only need provider access without orchestration.

## Next steps

- [Getting Started](getting_started.md) — install and run your first graph
- [Core Concepts: Graphs](graphs.md) — builder API in depth
- Coming from LangGraph? See [LangEx for LangGraph users](from_langgraph.md)
