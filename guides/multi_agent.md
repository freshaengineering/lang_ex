# Multi-Agent

LangEx ships two prebuilt **team** topologies. Both are ordinary compiled graphs: handoffs are tools that return `%LangEx.Command{}`, and the active agent is part of checkpointed state.

## Swarm (peer-to-peer)

Any agent can hand the conversation to any peer. The active agent is stored in `:active_agent` and persists across turns via the checkpointer.

```elixir
alias LangEx.Message

graph =
  LangEx.Prebuilt.Swarm.create(
    agents: [
      [model: "gpt-4o", name: :router, system_prompt: "Route the user to a specialist."],
      [model: "gpt-4o", name: :refunds, system_prompt: "Handle refund requests."],
      [model: "gpt-4o", name: :tech, system_prompt: "Debug product issues.", tools: [diag_tool]]
    ],
    default_active_agent: :router,
    checkpointer: LangEx.Checkpointer.Memory,
    add_agent_name: true
  )

{:ok, state} =
  LangEx.invoke(graph, %{messages: [Message.human("I want a refund")]},
    config: [thread_id: "t-1"]
  )

# Follow-up continues with whichever agent last held the turn
{:ok, state} =
  LangEx.invoke(graph, %{messages: [Message.human("Order #123")]},
    config: [thread_id: "t-1"]
  )
```

Each member automatically receives `transfer_to_<peer>` tools. Customize names with `:handoff_tool_prefix`.

## Supervisor (hub-and-spoke)

A supervisor delegates to workers that **return control** when done. Workers see a task-focused view; their output is reported back as an attributed user-role message so the supervisor can distinguish specialist findings from its own reasoning.

```elixir
graph =
  LangEx.Prebuilt.Supervisor.create(
    model: "gpt-4o",
    prompt: "You manage research and math specialists. Delegate, then summarize.",
    agents: [
      [model: "gpt-4o", name: :research, tools: [search_tool]],
      [model: "gpt-4o", name: :math, tools: [calc_tool]]
    ],
    checkpointer: LangEx.Checkpointer.Memory,
    output_mode: :full_history
  )
```

`:output_mode` is `:full_history` or `:last_message`.

## Building handoffs yourself

```elixir
tool = LangEx.Prebuilt.Handoff.tool(:billing, task_description: true)
# => Tool that updates active_agent / routes with an optional task brief
```

Handoffs are the same mechanism multi-agent teams use internally. Tool functions that return `%LangEx.Command{update: …, goto: …}` participate in routing after the tool node merges updates.

## Member options

Both topologies build members via `LangEx.Prebuilt.Member`:

| Option | Purpose |
|---|---|
| `:name` | Required unique agent atom |
| `:model` / `:provider` / tools / … | Forwarded to the chat node |
| `:system_prompt` | String or `(state -> string)` |
| `:pre_model_hook` | `messages -> messages` (trim, guardrails) |
| `:post_model_hook` | `update -> update` |
| Shared `:store` / `:context` | Available on each turn |

Teams accumulate token usage under `:llm_usage`.

## Choosing a topology

| Need | Prefer |
|---|---|
| Specialists freely pass the mic | **Swarm** |
| Central planner with clear return | **Supervisor** |
| Embed a team inside a larger graph | Nested `create/1` graph as a [subgraph](subgraphs.md) node |

## Scripts

| Script | Notes |
|---|---|
| `11_multi_agent.exs` | Swarm with scripted LLM — no API key |
| `12_multi_agent_live.exs` | Live Anthropic swarm |
| `13_supervisor_live.exs` | Live supervisor team |
| `14_workflow_live.exs` | Team inside a larger durable workflow |
