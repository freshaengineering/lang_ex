# Support Triage Router

A demo app showing LangEx's graph-based orchestration with Claude Opus, including human-in-the-loop interrupts with Postgres-backed checkpointing.

A user drops in a support request, and the graph routes it through one of four specialized branches:

- **qa** - answers a factual question
- **rewrite** - rewrites text in a professional tone
- **extract** - extracts structured JSON fields (issue_type, urgency, product, summary)
- **escalate** - drafts a formal escalation ticket, then **pauses for human approval** before completing

## Graph

```
__start__ --> router --> {qa, rewrite, extract, escalate}
                          |     |        |         |
                          v     v        v         v
                         qa  rewrite  extract  escalate
                          |     |        |         |
                          |     |        |         v
                          |     |        |      approve (INTERRUPT)
                          |     |        |         |
                          +-----+--------+---------+
                                    |
                                    v
                                  format --> __end__
```

The `approve` node calls `LangEx.Interrupt.interrupt/1`, pausing the graph and surfacing the drafted ticket for human review. When resumed with `true` or `false`, the graph continues to `format`.

## Setup

```bash
cd examples/support_triage
docker compose up -d
mix setup
export ANTHROPIC_API_KEY=...
```

## Run in iex

```bash
iex -S mix
```

Non-escalate intents complete in one shot:

```elixir
SupportTriage.run("How do I reset my password?")
SupportTriage.run("rewrite this: hey ur product is ok but the docs r confusing")
```

Escalate intent pauses at the approval interrupt. State is persisted in Postgres so you can resume later:

```elixir
{thread_id, _state} = SupportTriage.run("Everything is broken! This is urgent!")

# Resume with approval
SupportTriage.resume(thread_id, true)

# Or reject
SupportTriage.resume(thread_id, false)
```

## Tests

Tests use Ecto SQL Sandbox for isolation and Mimic to stub LLM calls (no API key needed):

```bash
mix test
```

| Test group | Count | What's tested |
|---|---|---|
| Routing | 4 | Each intent routes correctly (qa, rewrite, extract, escalate-as-interrupt) |
| Interrupts (Postgres) | 3 | Escalate pauses + resumes with approval, rejection, and non-escalate skips interrupt |
| Structure | 2 | Graph has all 7 nodes, checkpointer is set correctly |

## What This Demonstrates

- `Graph.add_conditional_edges` for intent-based routing
- `LangEx.Interrupt.interrupt/1` for human-in-the-loop approval
- `LangEx.Command{resume: value}` for resuming interrupted graphs
- `LangEx.Checkpointer.Postgres` for durable state persistence across pause/resume
- `MessagesState.schema` for pre-built message state with reducer
- `LangEx.LLM.Anthropic.chat/2` for direct LLM calls via Claude Opus
- Multiple LLM calls orchestrated across a branched graph

For small, runnable feature tours (no API key or database needed), see
[`examples/scripts`](../scripts).
