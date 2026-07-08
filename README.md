# LangEx

[![Hex.pm](https://img.shields.io/hexpm/v/lang_ex.svg)](https://hex.pm/packages/lang_ex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/lang_ex)
[![License](https://img.shields.io/hexpm/l/lang_ex.svg)](https://github.com/freshaengineering/lang_ex/blob/main/LICENSE)

Graph-based agent orchestration for Elixir. Build stateful, multi-step LLM workflows using nodes, edges, and conditional routing -- with the concurrency, fault tolerance, and streaming you get for free on the BEAM.

A production agent in one call:

```elixir
weather = %LangEx.Tool{
  name: "get_weather",
  description: "Get current weather for a city",
  parameters: %{type: "object", properties: %{city: %{type: "string"}}, required: ["city"]},
  function: fn %{"city" => city} -> "#{city}: 22°C, sunny" end
}

agent =
  LangEx.Prebuilt.agent(
    model: "claude-opus-4-20250514",
    system_prompt: "You are a concise weather assistant.",
    tools: [weather],
    checkpointer: LangEx.Checkpointer.Postgres
  )

{:ok, result} =
  LangEx.invoke(agent, %{messages: [Message.human("Weather in Tokyo?")]},
    config: [thread_id: "chat-42", repo: MyApp.Repo]
  )

List.last(result.messages).content  #=> "It's 22°C and sunny in Tokyo."
result.llm_usage                    #=> %{input_tokens: 613, output_tokens: 42, ...}
```

`Prebuilt.agent/1` wires the full loop for you: the LLM decides when to call tools and when to answer, results feed back in, token usage accumulates, the context window is compacted when it grows, and every step is checkpointed so the conversation can pause, crash, and resume. When the prebuilt shape isn't enough, the same loop is ~10 lines of graph code you control completely (see [Quick Start](#quick-start)).

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

    # Optional: for PostgreSQL checkpointing and the long-term store
    {:postgrex, "~> 0.19"},
    {:ecto_sql, "~> 3.12"},

    # Optional: to export traces via OpenTelemetry
    {:opentelemetry_api, "~> 1.2"},
    {:opentelemetry_telemetry, "~> 1.1"}
  ]
end
```

The core library has zero infrastructure dependencies. Add a checkpointer only if you need pause/resume or durability.

## Quick Start

Everything is a graph: nodes are functions from state to a state update, edges wire them together, conditional edges route on state. A minimal graph that routes messages by intent:

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

**How it works:** `Graph.new` defines the state schema (with optional reducers per key -- here new messages append instead of overwrite). `compile/2` validates the graph and catches wiring mistakes like routing to a node that doesn't exist. `invoke/3` runs it.

Every capability below has a self-contained ~40-line script in [`examples/scripts`](examples/scripts) that runs offline -- no API keys, no databases.

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

## What it can do

### Survive crashes

With a checkpointer attached, every super-step is persisted. If the VM dies mid-run, invoke the same thread with an empty input and execution continues from the last completed step -- finished work is never repeated:

```elixir
graph = Graph.compile(builder, checkpointer: LangEx.Checkpointer.Postgres)

{:ok, _} = LangEx.invoke(graph, %{}, config: [thread_id: "nightly-import", repo: Repo])
# ...crash at step 3 of 5, redeploy, then:
{:ok, result} = LangEx.invoke(graph, %{}, config: [thread_id: "nightly-import", repo: Repo])
# resumes at step 3
```

Checkpoint writes are tunable per invoke: `durability: :sync` (default), `:async` (off the hot path), or `:exit` (interrupts only).

### Pause for humans

Any node can stop the world and wait for input -- for approval flows, missing information, or dangerous actions. A node can ask several questions across resume cycles, and answers can arrive one at a time or all at once:

```elixir
Graph.add_node(:collect, fn _state ->
  name = LangEx.Interrupt.interrupt("What is your name?")
  email = LangEx.Interrupt.interrupt("What is your email?")
  %{summary: "registered #{name} <#{email}>"}
end)

{:interrupt, "What is your name?", _state} = LangEx.invoke(graph, %{}, config: config)
{:ok, result} = LangEx.invoke(graph, %Command{resume: %{"collect:0" => "Ada", "collect:1" => "ada@x.io"}}, config: config)
```

You can also pause *around* a node without touching its code -- `Graph.compile(builder, interrupt_before: [:deploy])` stops execution right before the risky step until someone resumes it.

### Rewind and fork

Checkpoints form a lineage, so a thread's history is inspectable and editable. Fetch any past state, correct it, and re-run from there -- the original timeline is preserved:

```elixir
history = LangEx.get_state_history(graph, config: [thread_id: "trip-1"])
{:ok, forked} = LangEx.update_state(graph, %{nights: 5}, config: [thread_id: "trip-1"])
{:ok, requoted} = LangEx.invoke(graph, %{nights: 5}, config: [thread_id: "trip-1"])
```

`LangEx.delete_thread/2` wipes a thread when a conversation is closed (or a user asks to be forgotten).

### Stream at the granularity you need

One graph, four lenses -- pick what the consumer cares about:

```elixir
graph
|> LangEx.stream(input, modes: [:messages, :values])
|> Enum.each(fn
  {:message_delta, %{text: chunk}} -> push_to_liveview(chunk)  # LLM tokens as they arrive
  {:values, state} -> update_dashboard(state)                  # full state after each step
  {:done, {:ok, result}} -> finish(result)
  _other -> :ok
end)
```

`:updates` (the default) yields per-node events, and `:custom` carries whatever nodes publish with `LangEx.Graph.Stream.emit/1` -- progress bars, intermediate findings, anything. Streams accept the same inputs as `invoke`, so an interrupted run can be resumed *while* streaming, and a crashed runner surfaces as an error event instead of killing the consumer.

### Remember across conversations

Checkpoints persist one thread; a store persists knowledge across all of them -- user preferences, learned facts, past decisions. Attach a backend at compile time and use it from any node or tool:

```elixir
graph = Graph.compile(builder, store: {LangEx.Store.Postgres, repo: Repo})

Graph.add_node(:remember, fn state ->
  :ok = LangEx.Store.put(["memories", state.user_id], "diet", "vegan")
  %{}
end)
```

### Fan out, fan in

Conditional edges can return `%LangEx.Send{}` structs to spawn one branch per work item at runtime -- map-reduce over data you only know when the graph runs. Reducers merge the results; a `defer: true` node waits for every branch before summarizing:

```elixir
|> Graph.add_conditional_edges(:plan, fn state ->
  Enum.map(state.urls, &%Send{node: :crawl, state: %{url: &1}})
end)
|> Graph.add_node(:report, &summarize/1, defer: true)
```

Parallelism is bounded: `invoke(graph, input, max_concurrency: 8, node_timeout: 30_000)`.

### Absorb failure

Flaky nodes retry with backoff, expensive nodes memoize, and LLM calls get rate-limit-aware retries with a fallback -- all declaratively:

```elixir
|> Graph.add_node(:fetch, &fetch_page/1, retry: [max_attempts: 3, backoff_ms: 200])
|> Graph.add_node(:classify, &classify/1, cache: [ttl: :timer.minutes(10)])
|> Graph.add_node(:llm, ChatModel.node(model: "gpt-4o", resilient: [max_retries: 3]))
```

### Compose graphs from graphs

A compiled graph is a node like any other. Interrupts raised three levels deep pause the whole run and resume through the layers; context and stream events flow through; and a subgraph can even route its parent with `%Command{goto: {:parent, :escalate}}`:

```elixir
approval = Graph.new(...) |> ... |> Graph.compile()

parent =
  Graph.new(...)
  |> Graph.add_node(:approval, approval)
  |> ...
```

### Watch every run

Telemetry spans cover the whole tree -- graph invoke, super-step, node, LLM call, checkpoint -- each carrying a `run_id`/`parent_run_id`, so a single invocation reconstructs into a trace. Ship it to OpenTelemetry with one line, and read token spend straight off the state:

```elixir
LangEx.Telemetry.OpenTelemetryBridge.attach()

Graph.new(llm_usage: {%{}, &ChatModel.merge_usage/2}, ...)  # per-run token accounting
```

And when you want to *see* a graph instead of reading it: `Graph.to_mermaid(graph)` renders the topology as a Mermaid flowchart.

## Extending LangEx

**Custom LLM provider** -- implement the `LangEx.LLM` behaviour (`chat/2`, plus `chat_with_usage/2` if the API reports token counts):

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

**Custom checkpointer** -- implement `LangEx.Checkpointer` (`save/2`, `load/1`, `list/2`, `delete_thread/1`). The [in-memory example](examples/scripts/support/in_memory_checkpointer.exs) is ~60 lines.

**Custom store** -- implement `LangEx.Store` (`get/3`, `put/4`, `delete/3`, `search/3`).

## Examples

| Example | What it demonstrates |
|---|---|
| [Feature Scripts](examples/scripts) | Runnable scripts — one per feature, no API keys or databases needed (`elixir examples/scripts/01_quick_start.exs`) |
| [Incident Responder](examples/incident_responder) | DevOps agent with tool chains, multi-turn conversation, conditional routing, Postgres checkpointing |
| [Support Triage](examples/support_triage) | Customer support agent with intent classification and escalation |

## License

MIT
