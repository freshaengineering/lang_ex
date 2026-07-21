# Long-Term Memory (Store)

Checkpoints remember **one thread**. A **store** remembers facts across threads — preferences, profiles, learned decisions.

## Attach a store

```elixir
graph =
  Graph.compile(builder,
    checkpointer: LangEx.Checkpointer.Postgres,
    store: LangEx.Store.ETS
  )

# or with options:
Graph.compile(builder, store: {LangEx.Store.Postgres, repo: MyApp.Repo})
```

Inside node (and tool) execution, call the convenience API — no plumbing:

```elixir
Graph.add_node(:remember, fn state ->
  :ok = LangEx.Store.put(["memories", state.user_id], "diet", "vegan")
  %{}
end)

Graph.add_node(:recall, fn state ->
  case LangEx.Store.get(["memories", state.user_id], "diet") do
    {:ok, diet} -> %{notes: "User is #{diet}"}
    :none -> %{}
  end
end)
```

`LangEx.Store.attached/0` returns `{module, config}` or `nil`.

## API

| Function | Behaviour |
|---|---|
| `get(ns, key)` | `{:ok, value}` \| `:none` \| `{:error, _}` |
| `put(ns, key, value)` | upsert |
| `delete(ns, key)` | remove |
| `search(ns, opts)` | list `{key, value}` — `:prefix`, `:limit` |

Namespaces are hierarchical lists of strings, e.g. `["memories", user_id]`.

## Backends

| Backend | Notes |
|---|---|
| `LangEx.Store.ETS` | In-memory, per-VM — tests / local |
| `LangEx.Store.Postgres` | Durable; tables created via `LangEx.Migration` |

Implement `LangEx.Store` (`get/3`, `put/4`, `delete/3`, `search/3`) for custom backends.

## vs checkpointer

| | Checkpointer | Store |
|---|---|---|
| Scope | One `thread_id` | Cross-thread namespaces |
| Contents | Execution progress + channel state | Your domain knowledge |
| Lifetime | Per conversation / job | Application-defined |

Use both: checkpoint for durability of the run, store for durable knowledge the agent reads/writes intentionally.
