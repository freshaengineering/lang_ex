# LangEx

[![Hex.pm](https://img.shields.io/hexpm/v/lang_ex.svg)](https://hex.pm/packages/lang_ex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/lang_ex)
[![License](https://img.shields.io/hexpm/l/lang_ex.svg)](https://github.com/surgeventures/lang_ex/blob/main/LICENSE)

Graph-based agent orchestration for Elixir. Build stateful, multi-step LLM workflows using nodes, edges, and conditional routing -- with the concurrency, fault tolerance, and streaming you get for free on the BEAM.

```elixir
tools = [
  %LangEx.Tool{
    name: "get_weather",
    description: "Get current weather for a city",
    parameters: %{type: "object", properties: %{city: %{type: "string"}}, required: ["city"]},
    function: fn %{"city" => city} -> "#{city}: 22°C, sunny" end
  }
]

graph =
  Graph.new(LangEx.MessagesState.schema())
  |> Graph.add_node(:agent, LangEx.LLM.ChatModel.node(model: "claude-opus-4-20250514", tools: tools))
  |> Graph.add_node(:tools, LangEx.Tool.Node.node(tools))
  |> Graph.add_edge(:__start__, :agent)
  |> Graph.add_conditional_edges(:agent, &LangEx.Tool.Node.tools_condition/1, %{
    tools: :tools,
    __end__: :__end__
  })
  |> Graph.add_edge(:tools, :agent)
  |> Graph.compile()

{:ok, result} = LangEx.invoke(graph, %{messages: [Message.human("Weather in Tokyo?")]})
```

Define a graph. Add nodes for LLM calls and tool execution. Wire them with edges and conditions. Compile. Invoke. The LLM decides when to call tools and when to respond -- LangEx orchestrates the loop.

## Why LangEx?

Python has [LangGraph](https://www.langchain.com/langgraph). Elixir deserves the same power, built on primitives that actually make sense for long-running, stateful agent workflows:

- **Parallel node execution** -- tool calls and graph nodes run concurrently via `Task.Supervisor`, not thread pools or async/await hacks
- **Lightweight state machines** -- graph state lives in function arguments and checkpoints, not GenServers; thousands of agent threads cost nothing
- **Interrupt and resume** -- pause execution for human approval, persist state to Redis or Postgres, resume hours later from exactly where you left off
- **Streaming for free** -- execution events are a lazy Elixir `Stream`; pipe them to Phoenix channels, LiveView, or Server-Sent Events
- **Fault tolerance** -- BEAM supervisors and process isolation mean one failing agent doesn't take down the rest

## Installation

```elixir
def deps do
  [
    {:lang_ex, "~> 0.5.0"},

    # Optional: for Redis checkpointing
    {:redix, "~> 1.5"},

    # Optional: for PostgreSQL checkpointing
    {:postgrex, "~> 0.19"},
    {:ecto_sql, "~> 3.12"}
  ]
end
```

The core library has zero infrastructure dependencies. Add a checkpointer only if you need pause/resume or durability.

## Quick Start

A minimal graph that routes messages by intent:

```elixir
alias LangEx.Graph
alias LangEx.Message

graph =
  Graph.new(messages: {[], &Message.add_messages/2}, intent: nil)
  |> Graph.add_node(:classify, fn state ->
    content = List.last(state.messages).content
    intent = if String.contains?(content, "weather"), do: "weather", else: "greeting"
    %{intent: intent}
  end)
  |> Graph.add_node(:weather, fn _state -> %{messages: [Message.ai("It's sunny today!")]} end)
  |> Graph.add_node(:greet, fn _state -> %{messages: [Message.ai("Hello there!")]} end)
  |> Graph.add_edge(:__start__, :classify)
  |> Graph.add_conditional_edges(:classify, &Map.get(&1, :intent), %{
    "weather" => :weather,
    "greeting" => :greet
  })
  |> Graph.add_edge(:weather, :__end__)
  |> Graph.add_edge(:greet, :__end__)
  |> Graph.compile()

{:ok, result} = LangEx.invoke(graph, %{messages: [Message.human("What's the weather?")]})
```

**How it works:** `Graph.new` defines the state schema (with optional reducers per key). Nodes are functions that receive state and return updates. Edges wire nodes together. Conditional edges route dynamically based on state. `compile/1` validates and freezes the graph. `invoke/2` runs it.

## Configuration

API keys are resolved in order: explicit opts, Application config, environment variables.

```elixir
# Environment variables (recommended)
# export ANTHROPIC_API_KEY=sk-ant-...

# Or application config
config :lang_ex, :anthropic, api_key: "sk-ant-..."
```

Model strings are auto-resolved to providers -- `"claude-opus-4-20250514"` routes to Anthropic, `"gemini-2.0-flash"` to Gemini, `"gpt-4o"` to OpenAI. Register custom providers at runtime:

```elixir
LangEx.LLM.Registry.register_provider(:groq, MyApp.LLM.Groq)
LangEx.LLM.Registry.register_prefix("llama-", :groq)
```

## Features

### Checkpointing

Persist graph state after each step for pause/resume, fault recovery, and time-travel debugging.

```elixir
graph = Graph.new(...) |> ... |> Graph.compile(checkpointer: LangEx.Checkpointer.Redis)

{:ok, result} = LangEx.invoke(graph, input, config: [thread_id: "my-thread"])
```

| | Redis | PostgreSQL |
|---|---|---|
| **Setup** | Add `redix` dep (auto-starts) | Add `ecto_sql` + run migration |
| **Best for** | Fast iteration, ephemeral workflows | Durable state, transactional guarantees |

For PostgreSQL, generate a migration and call `LangEx.Migration.up()`:

```elixir
defmodule MyApp.Repo.Migrations.AddLangEx do
  use Ecto.Migration

  def up, do: LangEx.Migration.up()
  def down, do: LangEx.Migration.down()
end
```

### Human-in-the-Loop Interrupts

Pause execution at any node, surface a payload to the caller, and resume with a human-provided value. Requires a checkpointer.

```elixir
graph =
  Graph.new(value: 0, approved: false)
  |> Graph.add_node(:check, fn state ->
    approval = LangEx.Interrupt.interrupt("Approve value #{state.value}?")
    %{approved: approval}
  end)
  |> Graph.add_node(:finalize, fn state -> %{value: state.value * 10} end)
  |> Graph.add_edge(:__start__, :check)
  |> Graph.add_edge(:check, :finalize)
  |> Graph.add_edge(:finalize, :__end__)
  |> Graph.compile(checkpointer: LangEx.Checkpointer.Redis)

# Pauses at the interrupt
{:interrupt, "Approve value 42?", _state} =
  LangEx.invoke(graph, %{value: 42}, config: [thread_id: "approval-1"])

# Resume with the human's decision
{:ok, result} =
  LangEx.invoke(graph, %LangEx.Command{resume: true}, config: [thread_id: "approval-1"])
```

### Streaming

Get a lazy stream of execution events:

```elixir
graph
|> LangEx.stream(%{value: 0})
|> Enum.each(fn
  {:node_start, name} -> IO.puts("Starting #{name}...")
  {:node_end, name, _update} -> IO.puts("Finished #{name}")
  {:done, {:ok, result}} -> IO.inspect(result, label: "Final")
  _ -> :ok
end)
```

### State Reducers

Each state key can have a custom merge function. The built-in `Message.add_messages/2` appends and deduplicates by ID; write your own for counters, sets, or domain-specific logic.

```elixir
Graph.new(
  messages: {[], &Message.add_messages/2},
  total: {0, fn old, new -> old + new end}
)
```

### Subgraphs

Use a compiled graph as a node inside another graph for composable, nested workflows:

```elixir
inner = Graph.new(value: 0) |> ... |> Graph.compile()

outer =
  Graph.new(value: 0, label: "")
  |> Graph.add_node(:sub, inner)
  |> Graph.add_node(:tag, fn _state -> %{label: "done"} end)
  |> Graph.add_edge(:__start__, :sub)
  |> Graph.add_edge(:sub, :tag)
  |> Graph.add_edge(:tag, :__end__)
  |> Graph.compile()
```

### Runtime Context

Inject dependencies into nodes without closures:

```elixir
Graph.add_node(:greet, fn _state, context ->
  %{greeting: "Hello from #{context.provider}!"}
end)

LangEx.invoke(graph, %{}, context: %{provider: "Anthropic"})
```

### Send (Fan-Out)

Dynamic map-reduce patterns from conditional edges using `%LangEx.Send{}`.

### Telemetry

All LLM calls and graph executions emit `:telemetry` events for observability.

## Extending LangEx

**Custom LLM provider** -- implement `LangEx.LLM` behaviour (`chat/2`):

```elixir
defmodule MyApp.LLM.Groq do
  @behaviour LangEx.LLM

  @impl true
  def chat(messages, opts) do
    # Call the Groq API
    {:ok, LangEx.Message.ai("response")}
  end
end

LangEx.LLM.Registry.register_provider(:groq, MyApp.LLM.Groq)
```

**Custom checkpointer** -- implement `LangEx.Checkpointer` behaviour (`save/2`, `load/1`, `list/2`).

## Examples

| Example | What it demonstrates |
|---|---|
| [Feature Scripts](examples/scripts) | Ten tiny, runnable scripts — one per feature, no API keys or databases needed (`elixir examples/scripts/01_quick_start.exs`) |
| [Incident Responder](examples/incident_responder) | DevOps agent with tool chains, multi-turn conversation, conditional routing, Postgres checkpointing |
| [Support Triage](examples/support_triage) | Customer support agent with intent classification and escalation |

## License

MIT
