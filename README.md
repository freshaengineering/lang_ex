# LangEx

[![Hex.pm](https://img.shields.io/hexpm/v/lang_ex.svg)](https://hex.pm/packages/lang_ex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/lang_ex)
[![License](https://img.shields.io/hexpm/l/lang_ex.svg)](https://github.com/surgeventures/lang_ex/blob/main/LICENSE)

**Graph-based agent orchestration for Elixir.** Stateful LLM workflows with nodes, edges, conditional routing, checkpointing, interrupts, and streaming — on BEAM primitives, not thread pools.

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

Define a graph. Wire LLM + tools. Compile. Invoke. LangEx runs the loop.

## Why LangEx?

Python has [LangGraph](https://www.langchain.com/langgraph). Elixir gets the same power with primitives that fit long-running agents:

- **Parallel by default** — nodes and tool calls via `Task.Supervisor`
- **Cheap threads** — state in args + checkpoints, not GenServers per conversation
- **Interrupt & resume** — human approval with Redis or Postgres durability
- **Streams for free** — lazy Elixir `Stream` → LiveView / channels / SSE
- **OTP resilience** — one failing run does not take down the rest

## Install

```elixir
def deps do
  [
    {:lang_ex, "~> 0.8.0"},
    {:redix, "~> 1.5"},          # optional — Redis checkpoints
    {:postgrex, "~> 0.19"},      # optional — Postgres checkpoints / store
    {:ecto_sql, "~> 3.12"}
  ]
end
```

```bash
export ANTHROPIC_API_KEY=sk-ant-...   # or OPENAI_API_KEY / GEMINI_API_KEY
```

## Documentation

**Full guides live on HexDocs** (source also under `guides/` in this repo):

| Start here | Then explore |
|---|---|
| [Introduction](https://hexdocs.pm/lang_ex/introduction.html) | [Graphs](https://hexdocs.pm/lang_ex/graphs.html) · [State](https://hexdocs.pm/lang_ex/state.html) |
| [Getting Started](https://hexdocs.pm/lang_ex/getting_started.html) | [Agents & Tools](https://hexdocs.pm/lang_ex/agents_and_tools.html) · [Multi-Agent](https://hexdocs.pm/lang_ex/multi_agent.html) |
| [Coming from LangGraph?](https://hexdocs.pm/lang_ex/from_langgraph.html) | [Checkpointing](https://hexdocs.pm/lang_ex/checkpointing.html) · [Human-in-the-Loop](https://hexdocs.pm/lang_ex/human_in_the_loop.html) |
| [Examples](https://hexdocs.pm/lang_ex/examples.html) | [Streaming](https://hexdocs.pm/lang_ex/streaming.html) · [Observability](https://hexdocs.pm/lang_ex/observability.html) |

API reference: [hexdocs.pm/lang_ex](https://hexdocs.pm/lang_ex).

## Try offline (no keys)

```bash
elixir examples/scripts/01_quick_start.exs
```

Fourteen feature scripts and two sample apps — see [Examples](https://hexdocs.pm/lang_ex/examples.html).

## License

MIT
