# Human-in-the-Loop

LangEx can **pause** a run, surface a payload to your application, and **resume** later with a human (or another system) providing a value. A checkpointer is required so the pause survives the request boundary.

## Dynamic interrupts

Call `LangEx.Interrupt.interrupt/1` inside a **graph node** (not inside a tool function or a spawned process):

```elixir
alias LangEx.Graph
alias LangEx.Interrupt

graph =
  Graph.new(value: 0, approved: false)
  |> Graph.add_node(:check, fn state ->
    approval = Interrupt.interrupt("Approve value #{state.value}?")
    %{approved: approval}
  end)
  |> Graph.add_node(:finalize, fn state -> %{value: state.value * 10} end)
  |> Graph.add_edge(:__start__, :check)
  |> Graph.add_edge(:check, :finalize)
  |> Graph.add_edge(:finalize, :__end__)
  |> Graph.compile(checkpointer: LangEx.Checkpointer.Memory)

{:interrupt, "Approve value 42?", _state} =
  LangEx.invoke(graph, %{value: 42}, config: [thread_id: "approval-1"])

{:ok, result} =
  LangEx.invoke(graph, %LangEx.Command{resume: true},
    config: [thread_id: "approval-1"]
  )
```

### Interrupt IDs

Each call site gets a stable id `"#{node}:#{index}"` (`"check:0"`, `"check:1"`, …). On resume:

- Pass a **single value** to answer the first pending interrupt.
- Pass a **map** `%{interrupt_id => value}` to answer several at once.

```elixir
LangEx.invoke(graph, %LangEx.Command{resume: %{"check:0" => true, "check:1" => "lgtm"}},
  config: [thread_id: "approval-1"]
)
```

### Re-run semantics

When you resume, the interrupted **node re-runs from the top**. Earlier `interrupt/1` calls return their recorded answers; execution continues until the next unanswered interrupt or completion.

**Implication:** side effects before an interrupt run again. Keep them idempotent, or move them to a later node.

### Parallel branches

If one branch of a parallel super-step interrupts, completed siblings keep their results **and** their routing. Nothing is re-executed or dropped on resume.

## Static breakpoints

Declare pause points at compile time without calling `interrupt/1`:

```elixir
Graph.compile(builder,
  checkpointer: LangEx.Checkpointer.Memory,
  interrupt_before: [:charge],
  interrupt_after: [:tools]
)
```

Resume the same way — with `%LangEx.Command{resume: …}`. Demo: `examples/scripts/08_breakpoints.exs`.

## Call-site restrictions

`interrupt/1` must run in the process executing the graph node. Calling it from:

- `LangEx.Tool` functions, or
- processes you spawn inside a node

raises (or becomes an error tool message when tool error handling is on). Put a dedicated **approval node** before/after the tool step instead.

## Application pattern

Typical Phoenix / LiveView flow:

1. `invoke` → match `{:interrupt, payload, state}`.
2. Persist `thread_id` with the user session or ticket.
3. Show `payload` in the UI.
4. On submit, `invoke` with `%Command{resume: answer}` and the same `thread_id`.

See `examples/scripts/05_human_in_the_loop.exs` for multi-interrupt patterns.
