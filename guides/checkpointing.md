# Checkpointing

Checkpointing persists graph progress so you can **pause**, **resume**, **recover crashes**, and **time-travel**. Without a checkpointer, each `invoke/3` is a single ephemeral run.

## Attach a checkpointer

```elixir
graph =
  Graph.new(...)
  |> ...
  |> Graph.compile(checkpointer: LangEx.Checkpointer.Memory)
```

Every invoke that should participate in a thread must pass `config: [thread_id: ...]`.

```elixir
LangEx.invoke(graph, input, config: [thread_id: "user-42-session"])
```

## Built-in backends

| Backend | Setup | Best for |
|---|---|---|
| `LangEx.Checkpointer.Memory` | Built-in | Tests, local scripts (lost on restart) |
| `LangEx.Checkpointer.Redis` | Add `{:redix, "~> 1.5"}` | Fast ephemeral durability |
| `LangEx.Checkpointer.Postgres` | Add `ecto_sql` + migration | Durable, transactional apps |

### Redis

LangEx starts a Redix connection from config when the optional dep is present. Point it at your instance via application env / URL (see integration tests and `docker-compose.yml` for local defaults).

### Postgres

Generate a migration that calls LangEx’s versioned migrator:

```elixir
defmodule MyApp.Repo.Migrations.AddLangEx do
  use Ecto.Migration

  def up, do: LangEx.Migration.up()
  def down, do: LangEx.Migration.down()
end
```

Pass the repo in invoke config when required by your backend options:

```elixir
LangEx.invoke(graph, input, config: [thread_id: "t-1", repo: MyApp.Repo])
```

(Exact keys depend on how you compile the checkpointer — see `LangEx.Checkpointer.Postgres` moduledoc.)

## Durability modes

Control when checkpoints are written with the `:durability` invoke option:

| Mode | Writes | Trade-off |
|---|---|---|
| `:sync` (default) | After every super-step, on the hot path | Strongest crash recovery |
| `:async` | After every super-step, supervised task | Lower latency; may lose latest step on crash |
| `:exit` | Only on interrupts, completion, failures | Fastest; mid-run crash restarts from `:__start__` |

Under every mode, checkpoints preserve full work entries — including pending `%LangEx.Send{}` payloads (checkpoint format **v2**) — so resume picks up exactly where the run stopped.

## Crash continue

After a crash, invoke with **empty input** on the same `thread_id`:

```elixir
{:ok, state} = LangEx.invoke(graph, %{}, config: [thread_id: "t-1"])
```

Non-empty input always starts a fresh pass from `:__start__` (merged onto the latest checkpointed state). This distinction is intentional:

| Input | Behaviour |
|---|---|
| `%{}` | Continue pending nodes from the last checkpoint |
| `%{…}` | New user turn / new pass from `:__start__` |
| `%Command{resume: …}` | Answer interrupts and continue |

See `examples/scripts/06_crash_recovery.exs`.

## History, fork, delete

```elixir
{:ok, latest} = LangEx.get_state(graph, config: [thread_id: "t-1"])
history = LangEx.get_state_history(graph, config: [thread_id: "t-1"])

{:ok, forked} =
  LangEx.update_state(graph, %{approved: true}, config: [thread_id: "t-1"])

:ok = LangEx.delete_thread(graph, config: [thread_id: "t-1"])
```

Load a specific checkpoint with `:checkpoint_id` in config (time travel). Demo: `examples/scripts/07_time_travel.exs`.

## What is stored

A checkpoint records roughly:

- channel / state values
- next work items (`next_nodes` — atoms **and** `%Send{}` structs)
- interrupt metadata and completed-sibling routing
- parent lineage for forks

You rarely need the raw shape; implement `LangEx.Checkpointer` if you need a custom store (S3, DynamoDB, …). Always persist `next_nodes` losslessly — use `LangEx.Checkpoint.Serializer`.

## Design tips

- Use a **stable `thread_id`** per conversation or business unit of work.
- Prefer **Postgres** when interrupts can last hours/days.
- For high-throughput ephemeral agents, **Redis + `:async`** is a common compromise.
- Combine with [Human-in-the-Loop](human_in_the_loop.md) for approval flows.
