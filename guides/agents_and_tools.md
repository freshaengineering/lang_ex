# Agents and Tools

Most production graphs are a **tool-calling loop**: an LLM proposes tool calls, a tool node executes them (often in parallel), and control returns to the LLM until it answers without tools.

## Prebuilt agent

```elixir
alias LangEx.Message
alias LangEx.Tool

search = %Tool{
  name: "search_docs",
  description: "Search internal docs",
  parameters: %{
    type: "object",
    properties: %{query: %{type: "string"}},
    required: ["query"]
  },
  function: fn %{"query" => q} -> MyApp.Docs.search(q) end
}

graph =
  LangEx.Prebuilt.agent(
    model: "gpt-4o",
    system_prompt: "Answer using search_docs when unsure.",
    tools: [search],
    checkpointer: LangEx.Checkpointer.Memory,
    compaction: [],                    # default context compaction
    interrupt_before: [],              # optional breakpoints
    tool_opts: [max_concurrency: 4]
  )

{:ok, state} =
  LangEx.invoke(graph, %{messages: [Message.human("How do refunds work?")]},
    config: [thread_id: "support-1"]
  )
```

State schema includes `:messages` and `:llm_usage`. Without tools, the graph is a single LLM turn ending at `:__end__`.

## Manual tool loop

Same shape, full control:

```elixir
alias LangEx.Graph
alias LangEx.LLM.ChatModel
alias LangEx.MessagesState
alias LangEx.Tool.Node

tools = [search]

graph =
  Graph.new(MessagesState.schema())
  |> Graph.add_node(:agent, ChatModel.node(model: "gpt-4o", tools: tools))
  |> Graph.add_node(:tools, Node.node(tools))
  |> Graph.add_edge(:__start__, :agent)
  |> Graph.add_conditional_edges(:agent, &Node.tools_condition/1, %{
    tools: :tools,
    __end__: :__end__
  })
  |> Graph.add_edge(:tools, :agent)
  |> Graph.compile()
```

`tools_condition/1` inspects the latest AI message: pending tool calls → `:tools`, otherwise → `:__end__`.

## Defining tools

```elixir
%LangEx.Tool{
  name: "get_order",
  description: "Fetch an order by id",
  parameters: %{
    type: "object",
    properties: %{
      order_id: %{type: "string", description: "Order UUID"}
    },
    required: ["order_id"]
  },
  function: fn args -> MyApp.Orders.get!(args["order_id"]) end
}
```

- `name` / `description` / `parameters` become the JSON-schema the model sees.
- `function` receives the decoded args map and returns any term (stringified into a tool message unless you return a `Command` — below).

### Tool → Command (handoffs)

A tool function may return `%LangEx.Command{}` to update state and steer routing (multi-agent handoffs use this):

```elixir
fn _args ->
  %LangEx.Command{
    update: %{active_agent: :billing},
    goto: :billing
  }
end
```

`Tool.Node` still synthesizes a `%Message.Tool{}` for the model when the command omits one, so the conversation stays valid.

## Tool.Node options

```elixir
LangEx.Tool.Node.node(tools,
  handle_tool_errors: true,
  max_concurrency: 8,
  timeout: 5_000
)
```

Tool calls in one AI message run **in parallel** (bounded). Failures can become error tool messages the LLM can recover from — see `LangEx.Tool.Annotation` for recovery hints.

## ChatModel node

```elixir
ChatModel.node(
  model: "claude-sonnet-4-20250514",
  tools: tools,
  messages_key: :messages,
  usage_key: :llm_usage,
  resilient: true,          # or [max_retries: 3, ...]
  temperature: 0.2
)
```

The LLM node **does not** execute tools; it only requests them. Pair with `Tool.Node`.

### Structured output

Provider-agnostic structured results via a synthetic `respond` tool:

```elixir
ChatModel.structured_node(
  model: "gpt-4o",
  schema: %{
    type: "object",
    properties: %{
      sentiment: %{type: "string", enum: ["pos", "neg", "neu"]},
      score: %{type: "number"}
    },
    required: ["sentiment", "score"]
  },
  into: :analysis
)
```

Decoded JSON lands in `:analysis` (or your `:into` key); a clean assistant message carries the JSON for chat history continuity.

## Context compaction

Long threads blow past context windows. `Prebuilt.agent/1` runs `LangEx.ContextCompaction.compact_if_needed/2` before each model call (disable with `compaction: false`). Tune budgets there when you need tighter control.

## Offline practice

`examples/scripts/04_agent_with_tools.exs` scripts a fake LLM — no API key — so you can study the loop locally.
