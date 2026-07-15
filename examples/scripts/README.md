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
| [06_crash_recovery.exs](06_crash_recovery.exs) | Durable execution: a crashed thread resumes from its pending nodes |
| [07_time_travel.exs](07_time_travel.exs) | Checkpoint history with parent lineage, `update_state/3` forking |
| [08_breakpoints.exs](08_breakpoints.exs) | Static `interrupt_before` breakpoints declared at compile time |
| [09_subgraphs.exs](09_subgraphs.exs) | A compiled graph as a node — interrupts pause and resume through it |
| [10_observability.exs](10_observability.exs) | Rebuilding the run tree from `run_id`/`parent_run_id` telemetry |
| [11_multi_agent.exs](11_multi_agent.exs) | A swarm of agents handing the conversation to one another — scripted LLM, no key needed |
| [12_multi_agent_live.exs](12_multi_agent_live.exs) | A customer-support swarm: front-line triage hands off to Billing/Tech specialists (with tools), active agent persisted across turns — **requires a real `ANTHROPIC_API_KEY`** |
| [13_supervisor_live.exs](13_supervisor_live.exs) | A supervisor incident-response team delegating to diagnostics/runbook/comms specialists and synthesizing a summary — **requires a real `ANTHROPIC_API_KEY`** |
| [14_workflow_live.exs](14_workflow_live.exs) | A team embedded in a larger graph with Command routing, human-in-the-loop approval, long-term store, and durable persistence — **requires a real `ANTHROPIC_API_KEY`** |
| [15_supervisor_parallel.exs](15_supervisor_parallel.exs) | A supervisor delegating to several workers concurrently (`parallel: true`) and fanning their attributed results back in one step — scripted LLM, no key needed |
| [16_in_member_hitl_live.exs](16_in_member_hitl_live.exs) | In-member human-in-the-loop: a `:pre_model_hook` interrupt pauses mid-member and resumes at the team level, with the reply streamed token-by-token — **requires a real `ANTHROPIC_API_KEY`** |
| [17_parallel_supervisor_live.exs](17_parallel_supervisor_live.exs) | A travel lead delegating to flights + hotels agents concurrently (`parallel: true`) and combining their findings — **requires a real `ANTHROPIC_API_KEY`** |
| [18_prebuilt_worker_forward_live.exs](18_prebuilt_worker_forward_live.exs) | A pre-built `Prebuilt.agent/1` used as a supervisor worker, whose answer the supervisor forwards verbatim via the `forward_message` tool — **requires a real `ANTHROPIC_API_KEY`** |
| [19_structured_output_live.exs](19_structured_output_live.exs) | A supervisor with `response_format` decoding its final answer into a typed `:structured_response` — **requires a real `ANTHROPIC_API_KEY`** |
| [20_team_breakpoint_live.exs](20_team_breakpoint_live.exs) | A swarm compiled with `interrupt_before: [:refunds]` — a manager approval gate that pauses before a specialist agent runs — **requires a real `ANTHROPIC_API_KEY`** |
| [21_hierarchical_team_live.exs](21_hierarchical_team_live.exs) | Hierarchical teams: a supervisor whose worker is itself a supervisor coordinating two specialists — **requires a real `ANTHROPIC_API_KEY`** |
| [22_custom_state_live.exs](22_custom_state_live.exs) | A swarm sharing a custom reducer-backed `:checklist` state key, accumulated exactly once across a handoff — **requires a real `ANTHROPIC_API_KEY`** |

The scripts that pause and resume use
[`support/in_memory_checkpointer.exs`](support/in_memory_checkpointer.exs),
a ~50-line Agent-backed implementation of the `LangEx.Checkpointer`
behaviour — also a template for writing your own backend. In production,
use `LangEx.Checkpointer.Redis` or `LangEx.Checkpointer.Postgres`.

For full applications with real LLM calls, see
[incident_responder](../incident_responder) and
[support_triage](../support_triage).
