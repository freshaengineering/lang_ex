# State and Reducers

LangEx graphs are **state machines**. Every run carries a map of keys; nodes return partial updates that merge into that map.

## Declaring a schema

Pass a keyword list to `Graph.new/1`:

```elixir
Graph.new(
  # Last-write-wins (default): new value replaces old
  intent: nil,
  score: 0,

  # Accumulator: {initial, reducer}
  messages: {[], &LangEx.Message.add_messages/2},
  total: {0, fn old, new -> old + new end},
  tags: {MapSet.new(), fn old, new -> MapSet.union(old, MapSet.new(List.wrap(new))) end}
)
```

| Form | Meaning |
|---|---|
| `key: default` | Initial value; updates overwrite |
| `key: {default, fun}` | Initial value; updates merge with `fun.(old, new)` |

After compile, the schema becomes the graph’s initial state plus a reducer table. Keys not in the schema are rejected when applying updates (stick to declared keys).

## How merges work

When a node returns `%{messages: [msg], score: 1}`:

1. For each key in the update, look up a reducer.
2. If present: `reducers[key].(current[key], update[key])`.
3. If absent: `update[key]` replaces `current[key]`.

Parallel nodes in one super-step each produce updates; those updates are merged in a deterministic order onto the shared state before the next step.

## Message lists

Chat agents almost always use:

```elixir
alias LangEx.Message
alias LangEx.MessagesState

# Explicit
Graph.new(messages: {[], &Message.add_messages/2})

# Convenience schema (+ whatever else you add)
Graph.new(MessagesState.schema())
```

`Message.add_messages/2` **appends** and **deduplicates by message id**, so retried or overlapping updates do not double-insert the same turn.

### Message constructors

```elixir
Message.human("Hi")
Message.ai("Hello!")
Message.system("You are helpful.")
Message.tool_result(tool_call_id, "payload")
```

Structs live under `LangEx.Message.Human`, `.AI`, `.System`, `.Tool`.

## Token usage

Accumulate usage across LLM nodes with `ChatModel.merge_usage/2`:

```elixir
alias LangEx.LLM.ChatModel

Graph.new(
  messages: {[], &Message.add_messages/2},
  llm_usage: {%{}, &ChatModel.merge_usage/2}
)
```

`ChatModel.node/1` writes usage only when `:llm_usage` (or your `:usage_key`) exists in the schema.

## Inspecting and editing state

With a checkpointer and `thread_id`:

```elixir
{:ok, cp} = LangEx.get_state(graph, config: [thread_id: "t-1"])
history = LangEx.get_state_history(graph, config: [thread_id: "t-1"])

# Fork: write a new checkpoint with an update applied
{:ok, forked} =
  LangEx.update_state(graph, %{intent: "escalated"}, config: [thread_id: "t-1"])

LangEx.delete_thread(graph, config: [thread_id: "t-1"])
```

Time-travel and forking are demonstrated in `examples/scripts/07_time_travel.exs`.

## Managed / parallel write conflicts

When two parallel tool calls (or nodes) write different values to the same non-reduced key in one super-step, LangEx keeps the **earliest** value and logs a warning. Prefer reducers for keys that legitimately accumulate, and avoid divergent handoffs in a single batch.

## Recipes

**Counter**

```elixir
steps: {0, fn old, new -> old + new end}
# node returns %{steps: 1}
```

**List append**

```elixir
events: {[], &Kernel.++/2}
# node returns %{events: [%{type: :charged}]}
```

**Replaceable scalar**

```elixir
status: :pending
# node returns %{status: :done}
```
