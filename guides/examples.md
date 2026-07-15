# Examples

Runnable examples live in the repository under [`examples/`](https://github.com/surgeventures/lang_ex/tree/main/examples).

## Feature scripts (offline-first)

Tiny scripts — one feature each. Most need **no API keys and no databases**.

```bash
elixir examples/scripts/01_quick_start.exs
```

| Script | Demonstrates |
|---|---|
| [`01_quick_start.exs`](https://github.com/surgeventures/lang_ex/blob/main/examples/scripts/01_quick_start.exs) | Nodes, edges, conditionals, reducers |
| [`02_streaming.exs`](https://github.com/surgeventures/lang_ex/blob/main/examples/scripts/02_streaming.exs) | Lazy event stream + `{:done, …}` |
| [`03_send_map_reduce.exs`](https://github.com/surgeventures/lang_ex/blob/main/examples/scripts/03_send_map_reduce.exs) | Dynamic `Send` fan-out, concurrency caps |
| [`04_agent_with_tools.exs`](https://github.com/surgeventures/lang_ex/blob/main/examples/scripts/04_agent_with_tools.exs) | Tool-calling loop (scripted LLM) |
| [`05_human_in_the_loop.exs`](https://github.com/surgeventures/lang_ex/blob/main/examples/scripts/05_human_in_the_loop.exs) | `interrupt/1`, batch resume |
| [`06_crash_recovery.exs`](https://github.com/surgeventures/lang_ex/blob/main/examples/scripts/06_crash_recovery.exs) | Continue from pending nodes |
| [`07_time_travel.exs`](https://github.com/surgeventures/lang_ex/blob/main/examples/scripts/07_time_travel.exs) | History + `update_state/3` forks |
| [`08_breakpoints.exs`](https://github.com/surgeventures/lang_ex/blob/main/examples/scripts/08_breakpoints.exs) | Static `interrupt_before` |
| [`09_subgraphs.exs`](https://github.com/surgeventures/lang_ex/blob/main/examples/scripts/09_subgraphs.exs) | Nested compiled graphs |
| [`10_observability.exs`](https://github.com/surgeventures/lang_ex/blob/main/examples/scripts/10_observability.exs) | Run-tree from telemetry |
| [`11_multi_agent.exs`](https://github.com/surgeventures/lang_ex/blob/main/examples/scripts/11_multi_agent.exs) | Swarm handoffs (scripted LLM) |
| [`12_multi_agent_live.exs`](https://github.com/surgeventures/lang_ex/blob/main/examples/scripts/12_multi_agent_live.exs) | Live support swarm (**API key**) |
| [`13_supervisor_live.exs`](https://github.com/surgeventures/lang_ex/blob/main/examples/scripts/13_supervisor_live.exs) | Live supervisor team (**API key**) |
| [`14_workflow_live.exs`](https://github.com/surgeventures/lang_ex/blob/main/examples/scripts/14_workflow_live.exs) | Team in a durable outer workflow (**API key**) |

Scripts that pause/resume use [`support/in_memory_checkpointer.exs`](https://github.com/surgeventures/lang_ex/blob/main/examples/scripts/support/in_memory_checkpointer.exs) — a short custom checkpointer you can copy as a template.

## Application examples

| App | What it shows |
|---|---|
| [Incident Responder](https://github.com/surgeventures/lang_ex/tree/main/examples/incident_responder) | DevOps agent, tool chains, multi-turn, Postgres checkpoints |
| [Support Triage](https://github.com/surgeventures/lang_ex/tree/main/examples/support_triage) | Intent classification and escalation |

Each app has its own `mix.exs` and README with setup steps.

## Learning path

1. Run `01` → `04` to learn the builder and tool loop.
2. Run `05` → `08` for durability and human approval.
3. Run `09` → `11` for composition and teams.
4. Point live scripts at a real key when you want end-to-end model behaviour.
5. Skim an application example before integrating into Phoenix.
