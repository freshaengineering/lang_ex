# LangEx for LangGraph Users

If you already know [LangGraph](https://langchain-ai.github.io/langgraph/), this page maps concepts to LangEx idioms so you can transfer muscle memory quickly.

## At a glance

| LangGraph | LangEx |
|---|---|
| `StateGraph` | `LangEx.Graph` builder |
| `graph.compile()` | `Graph.compile/1` → `LangEx.Graph.Compiled` |
| `graph.invoke(input, config)` | `LangEx.invoke(graph, input, opts)` |
| `graph.stream(...)` | `LangEx.stream(graph, input, opts)` |
| `TypedDict` / channels | Schema keyword + reducers in `Graph.new/1` |
| `add_messages` | `Message.add_messages/2` |
| `tools_condition` | `LangEx.Tool.Node.tools_condition/1` |
| `ToolNode` | `LangEx.Tool.Node.node/1` |
| `interrupt()` | `LangEx.Interrupt.interrupt/1` |
| `Command(resume=…)` | `%LangEx.Command{resume: …}` |
| `Send(node, arg)` | `%LangEx.Send{node: …, state: …}` |
| Checkpointer (Memory/Sqlite/Postgres) | Memory / Redis / Postgres |
| `thread_id` in config | `config: [thread_id: …]` |
| Pregel supersteps | Same model (`LangEx.Graph.Pregel`) |
| Subgraphs as nodes | Pass a `Compiled` into `add_node/3` |

## Build and run

**LangGraph (Python)**

```python
graph = StateGraph(State)
graph.add_node("agent", call_model)
graph.add_edge(START, "agent")
app = graph.compile(checkpointer=memory)
app.invoke({"messages": […]}, config={"configurable": {"thread_id": "1"}})
```

**LangEx (Elixir)**

```elixir
graph =
  Graph.new(MessagesState.schema())
  |> Graph.add_node(:agent, ChatModel.node(model: "gpt-4o"))
  |> Graph.add_edge(:__start__, :agent)
  |> Graph.add_edge(:agent, :__end__)
  |> Graph.compile(checkpointer: LangEx.Checkpointer.Memory)

LangEx.invoke(graph, %{messages: […]}, config: [thread_id: "1"])
```

## State channels vs reducers

LangGraph channels with reducers become `{default, fun}` schema entries:

```elixir
Graph.new(
  messages: {[], &Message.add_messages/2},
  count: {0, fn a, b -> a + b end}
)
```

Last-write-wins keys are plain `key: default` — no reducer.

## Interrupts

Same rule-of-thumb: **side effects before `interrupt` re-run**. Resume with `Command`.

LangEx requires interrupts inside graph node processes (not tool functions). Static breakpoints map to `interrupt_before` / `interrupt_after` compile options.

## Multi-agent

LangGraph’s swarm / supervisor patterns map to:

- `LangEx.Prebuilt.Swarm.create/1`
- `LangEx.Prebuilt.Supervisor.create/1`
- `LangEx.Prebuilt.Handoff.tool/2`

Handoffs remain tool calls that return `Command`.

## What feels different

1. **Pipeline builders** — Elixir pipes replace method chaining; compile freezes the builder.
2. **Streams are Elixir Streams** — not async iterators; consume with `Enum` / LiveView.
3. **No GenServer per thread** — state lives in args + checkpoints (cheaper at scale).
4. **OTP policies** — retry/timeout/cache/defer live on `add_node/4`, not a separate runtime config object.
5. **Hex packaging** — optional Redis/Postgres/OTel deps; core stays light.
6. **Return tags** — prefer `{:ok, _} | {:interrupt, _, _} | {:error, %NodeError{}}` over exceptions for node failure.

## Suggested reading order

1. [Getting Started](getting_started.md)
2. [Graphs](graphs.md) + [State](state.md)
3. [Checkpointing](checkpointing.md) + [Human-in-the-Loop](human_in_the_loop.md)
4. [Agents and Tools](agents_and_tools.md)
5. [Multi-Agent](multi_agent.md)
