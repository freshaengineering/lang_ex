# Feature Scripts

Small, self-contained scripts — one per feature. Every script runs
offline (no API keys, no databases, no docker) except the live examples
noted below, which call a real model. Dependencies resolve via
`Mix.install/1` against the library in this repository.

```bash
elixir examples/scripts/01_quick_start.exs
```

Run them in order — each builds on the ideas of the previous one.

| Script | Feature |
|---|---|
| [01_quick_start.exs](01_quick_start.exs) | Nodes, edges, conditional routing, state reducers |
| [02_streaming.exs](02_streaming.exs) | Lazy event stream: step/node events, crash-safe `{:done, ...}` |
| [03_send_map_reduce.exs](03_send_map_reduce.exs) | Dynamic `Send` fan-out with `max_concurrency` and `node_timeout` |
| [04_agent_with_tools.exs](04_agent_with_tools.exs) | Tool-calling agent loop (`ChatModel` + `Tool.Node`) with token usage accounting — scripted LLM, no key needed |
| [05_human_in_the_loop.exs](05_human_in_the_loop.exs) | `interrupt/1` with stable IDs, resuming one answer at a time or all at once |
| [06_crash_recovery.exs](06_crash_recovery.exs) | Durable execution: a crashed thread resumes from its pending nodes, and finished parallel tasks are replayed from the write journal rather than re-run |
| [07_time_travel.exs](07_time_travel.exs) | Checkpoint history with parent lineage and `:source` provenance, `update_state/3` forking |
| [08_breakpoints.exs](08_breakpoints.exs) | Static `interrupt_before` breakpoints declared at compile time |
| [09_subgraphs.exs](09_subgraphs.exs) | A compiled graph as a node — interrupts pause and resume through it |
| [10_observability.exs](10_observability.exs) | Rebuilding the run tree from `run_id`/`parent_run_id` telemetry |
| [11_multi_agent.exs](11_multi_agent.exs) | A swarm of agents handing the conversation to one another — scripted LLM, no key needed |
| [12_multi_agent_live.exs](12_multi_agent_live.exs) | A customer-support swarm: front-line triage hands off to Billing/Tech specialists (with tools), active agent persisted across turns — **requires a real `ANTHROPIC_API_KEY`** |
| [13_supervisor_live.exs](13_supervisor_live.exs) | A supervisor incident-response team delegating to diagnostics/runbook/comms specialists and synthesizing a summary — **requires a real `ANTHROPIC_API_KEY`** |
| [14_workflow_live.exs](14_workflow_live.exs) | A team embedded in a larger graph with Command routing, human-in-the-loop approval, long-term store, and durable persistence — **requires a real `ANTHROPIC_API_KEY`** |
| [15_parallel_approvals.exs](15_parallel_approvals.exs) | Fan-out where each `Send` branch pauses for its own approval and is answered independently |
| [16_engine_policies.exs](16_engine_policies.exs) | Scoped fan-in barriers, ephemeral state keys, graph-wide node defaults, and cache keys |
| [17_thread_lifecycle.exs](17_thread_lifecycle.exs) | Provenance-filtered history, cursor pagination, branching a thread with `copy_thread/3`, namespace-aware delete |
| [18_agent_middleware.exs](18_agent_middleware.exs) | Tool approval with argument correction, tool retry, a call budget, model-request overrides, and run-scoped hooks — scripted LLM, no key needed |
| [19_encrypted_checkpoints.exs](19_encrypted_checkpoints.exs) | Encrypting checkpoint payloads at rest, with a plaintext allowlist and key rotation |
| [20_team_member_interrupts.exs](20_team_member_interrupts.exs) | `interrupt/1` inside a swarm or supervisor member pauses the parent thread; resume continues the member — scripted LLM, no key needed |

The scripts that pause and resume use
[`support/in_memory_checkpointer.exs`](support/in_memory_checkpointer.exs),
a ~60-line Agent-backed implementation of the `LangEx.Checkpointer`
behaviour — also a template for writing your own backend. In production,
use `LangEx.Checkpointer.Redis` or `LangEx.Checkpointer.Postgres`.

Two scripts reach for a different backend on purpose: 06 and 17 use the
built-in `LangEx.Checkpointer.Memory` for the parts that need the
optional callbacks (the per-task write journal, thread copying) that the
minimal template leaves out, and 19 defines a backend that stores the
encoded payload so the encrypted bytes can be printed.

For full applications with real LLM calls, see
[incident_responder](../incident_responder) and
[support_triage](../support_triage).
