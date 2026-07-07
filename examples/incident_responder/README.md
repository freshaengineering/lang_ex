# Incident Responder

A demo app showing LangEx's `ToolNode` pattern in a DevOps incident response agent. The agent triages alerts, runs diagnostics, and takes remediation actions through a conversational interface with interrupt-based turn-taking.

## Graph

```
__start__ --> greet --> await_input (INTERRUPT)
                            |
                            v
                          router
                         /  |  \
                        v   v   v
              question  incident  goodbye
                 |         |        |
                 v         v        v
           answer_q   triage_incident  __end__
                 |      /        \
                 |     v          v
                 |  await_input  execute_action
                 |               /          \
                 |              v             v
                 |         await_input     escalate
                 |              |             |
                 +--------------+-------------+
                        |
                        v
                   await_input (loop)
```

The `await_input` node calls `LangEx.Interrupt.interrupt/1`, pausing the graph and returning the agent's response. When resumed with a user message, the graph continues through the router.

`triage_incident` uses the **ToolNode pattern**: the LLM returns `tool_calls`, a `ToolNode` executes them via `%LangEx.Tool{function: ...}`, and results feed back to the LLM — no `tool_executor` callback needed.

## Tools (stubbed)

| Tool | Description |
|---|---|
| `check_service_health` | Returns status, latency, error rate, pod health for a service |
| `get_recent_logs` | Returns last 5 log entries with timestamps and levels |
| `get_metrics` | Returns CPU, memory, request rate, p99 latency |
| `restart_service` | Triggers a rolling restart (returns confirmation) |
| `page_oncall` | Pages the on-call engineer via PagerDuty |
| `update_status_page` | Updates status.acme.com with incident status |

All tools return hardcoded fake data — no external services required.

## Knowledge Base

- **Services**: api-gateway (Go), user-service (Elixir), payment-service (Java), notification-service (Python)
- **Runbooks**: step-by-step remediation per service
- **On-call**: Sarah Kim (primary), Marcus Chen (secondary), Priya Patel (IC)
- **Severity**: SEV1 (5min), SEV2 (15min), SEV3 (1hr), SEV4 (next business day)

## Setup

```bash
cd examples/incident_responder
docker compose up -d
mix setup
export ANTHROPIC_API_KEY=...
```

Uses Postgres for checkpointing. `docker compose up -d` starts a local Postgres, and `mix setup` creates the database and runs migrations.

## Run in iex

```bash
iex -S mix
```

Start an interactive session:

```elixir
IncidentResponder.repl()
```

Example conversation:

```
=== Acme Platform - Incident Response ===

Ops: Hey, Ops here. What's the situation?

You: api-gateway is throwing 503s, customers are complaining

Ops: Let me check the health of api-gateway right now.
  [TOOL] check_service_health(api-gateway)
api-gateway is degraded — 2 of 3 pods are unhealthy, error rate is 12.4%,
latency is at 2.3 seconds. Let me pull the recent logs.
  [TOOL] get_recent_logs(api-gateway)
The logs show upstream connection refused errors to user-service and a circuit
breaker open for payment-service. Let me check if those dependencies are healthy.
  [TOOL] check_service_health(user-service)
  [TOOL] check_service_health(payment-service)
user-service looks fine, but payment-service is degraded too — connection pool
exhaustion and Stripe timeouts. This looks like a SEV2. Want me to restart
payment-service and page on-call?

You: yes, do it

Ops: Restarting payment-service now.
  [TOOL] restart_service(payment-service)
  [TOOL] page_oncall(SEV2, payment-service)
Rolling restart initiated — 3 new pods spinning up. Sarah Kim has been paged
via PagerDuty. The Stripe timeouts may resolve once the connection pool resets.
Want me to update the status page?

You: yes, mark it as investigating

Ops: Done.
  [TOOL] update_status_page(payment-service, investigating)
Status page updated at status.acme.com. I'll keep an eye on things.
Anything else?

You: no, that's it for now

Ops: All clear. Don't forget to file the post-mortem. Ping me if it flares up again.
[Incident closed]
```

Or use the programmatic API:

```elixir
{:ok, session_id, greeting} = IncidentResponder.start_session()
{:ok, response} = IncidentResponder.chat(session_id, "api-gateway is returning 503s")
{:ok, response} = IncidentResponder.chat(session_id, "yes, restart it")
```

## What This Demonstrates

- `LangEx.Tool.Node.node/2` for executing diagnostic and action tools as a graph node
- `LangEx.Tool.Node.tools_condition/1` for routing based on tool calls
- `%LangEx.Tool{function: fn args -> ... end}` for tools with embedded implementations
- Multi-step tool chains (health check -> logs -> metrics -> action) in a single triage node
- `LangEx.Interrupt.interrupt/1` for multi-turn conversation
- `LangEx.Command{resume: message}` for resuming with user input
- `Graph.add_conditional_edges` for intent-based routing (question vs incident vs goodbye)
- `LangEx.LLM.Resilient.chat/3` for LLM calls with retries, backoff, and a fallback message
- `LangEx.Checkpointer.Postgres` for durable session state

For small, runnable feature tours (no API key or database needed), see
[`examples/scripts`](../scripts).
