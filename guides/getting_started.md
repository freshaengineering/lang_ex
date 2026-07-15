# Getting Started

This guide gets you from zero to a running graph in a few minutes.

## Requirements

- Elixir `~> 1.16`
- An LLM API key only if you call a live provider (many examples run offline)

## Installation

Add LangEx to your `mix.exs`:

```elixir
def deps do
  [
    {:lang_ex, "~> 0.8.0"},

    # Optional: Redis checkpointing
    {:redix, "~> 1.5"},

    # Optional: Postgres checkpointing / store
    {:postgrex, "~> 0.19"},
    {:ecto_sql, "~> 3.12"}
  ]
end
```

Then:

```bash
mix deps.get
```

The core library needs no Redis or Postgres. Add those dependencies only when you want durable pause/resume or long-term memory.

## Configure an API key (optional)

Keys resolve in order: **explicit opts → Application config → environment variables**.

```bash
export ANTHROPIC_API_KEY=sk-ant-...
# or OPENAI_API_KEY=..., GEMINI_API_KEY=...
```

```elixir
# config/runtime.exs
config :lang_ex, :anthropic, api_key: System.fetch_env!("ANTHROPIC_API_KEY")
```

Model strings auto-resolve to providers: `"claude-…"` → Anthropic, `"gpt-…"` → OpenAI, `"gemini-…"` → Gemini. See [Configuration](configuration.md).

## Your first graph

A tiny router — no API key required:

```elixir
alias LangEx.Graph

graph =
  Graph.new(log: {[], &Kernel.++/2}, intent: nil, reply: nil)
  |> Graph.add_node(:classify, fn state ->
    intent =
      if String.contains?(hd(state.log), "weather"),
        do: :weather,
        else: :greeting

    %{intent: intent, log: ["classified"]}
  end)
  |> Graph.add_node(:weather, fn _state ->
    %{reply: "It's 22°C and sunny.", log: ["answered weather"]}
  end)
  |> Graph.add_node(:greet, fn _state ->
    %{reply: "Hello there!", log: ["greeted"]}
  end)
  |> Graph.add_edge(:__start__, :classify)
  |> Graph.add_conditional_edges(:classify, & &1.intent, %{
    weather: :weather,
    greeting: :greet
  })
  |> Graph.add_edge(:weather, :__end__)
  |> Graph.add_edge(:greet, :__end__)
  |> Graph.compile()

{:ok, result} = LangEx.invoke(graph, %{log: ["what's the weather like?"]})
# result.intent == :weather
# result.reply  == "It's 22°C and sunny."
```

What just happened:

1. `Graph.new/1` declares state keys (`log` accumulates via a reducer; `intent` / `reply` are last-write-wins).
2. Nodes return **partial updates** — maps that merge into state.
3. Conditional edges call a routing function and map its return value to the next node.
4. `compile/1` freezes the graph; `LangEx.invoke/2` runs it from `:__start__` to `:__end__`.

Run the same idea from the repo:

```bash
elixir examples/scripts/01_quick_start.exs
```

## Tool-calling agent (one function)

For the canonical “LLM ↔ tools” loop, use the prebuilt constructor:

```elixir
alias LangEx.Message
alias LangEx.Tool

weather = %Tool{
  name: "get_weather",
  description: "Current weather for a city",
  parameters: %{
    type: "object",
    properties: %{city: %{type: "string"}},
    required: ["city"]
  },
  function: fn %{"city" => city} -> "#{city}: 22°C, sunny" end
}

graph =
  LangEx.Prebuilt.agent(
    model: "claude-opus-4-20250514",
    system_prompt: "You are a concise weather assistant.",
    tools: [weather]
  )

{:ok, result} =
  LangEx.invoke(graph, %{messages: [Message.human("Weather in Tokyo?")]})
```

Under the hood this builds a `ChatModel` node, a `Tool.Node`, and the conditional loop between them. Details: [Agents and Tools](agents_and_tools.md).

## Where to go next

| Goal | Guide |
|---|---|
| Understand nodes, edges, compile/invoke | [Graphs](graphs.md) |
| Custom merge logic for state keys | [State and Reducers](state.md) |
| Persist and resume threads | [Checkpointing](checkpointing.md) |
| Ask a human mid-run | [Human-in-the-Loop](human_in_the_loop.md) |
| Push events to LiveView | [Streaming](streaming.md) |
| Multi-agent teams | [Multi-Agent](multi_agent.md) |
| Offline feature scripts | [Examples](examples.md) |
