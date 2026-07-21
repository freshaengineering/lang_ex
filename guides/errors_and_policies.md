# Errors and Policies

LangEx separates **expected runtime failure** from **programmer mistakes**.

## Structured node errors

Node exceptions never escape `invoke/3` / `stream/3` as bare raises (after retry exhaustion). You get:

```elixir
{:error, %LangEx.NodeError{node: :fetch, reason: %Req.TransportError{}}} =
  LangEx.invoke(graph, input)
```

| Field | Meaning |
|---|---|
| `:node` | Failing node name |
| `:reason` | Original exception / cause |

`{:done, {:error, %NodeError{}}}` is the streaming counterpart.

### What still raises

Builder and routing mistakes raise with descriptive messages:

- edges / conditionals pointing at undefined nodes
- missing conditional path keys
- reserved / duplicate node names
- invalid `add_node` options

Fix these in the graph definition — they are not retryable run failures.

## Per-node policies

```elixir
Graph.add_node(graph, :fetch, &fetch_data/1,
  timeout: 10_000,
  retry: [
    max_attempts: 4,
    initial_interval_ms: 200,
    backoff_factor: 2.0,
    max_interval_ms: 5_000,
    jitter: true
  ],
  on_error: fn exception, _state ->
    %{fetch_failed: Exception.message(exception)}
  end,
  cache: [ttl: 60_000]
)
```

### Retry

- Retries **exceptions** only.
- Returning `{:error, _}` from a node is an ordinary result (not auto-retried).
- See `LangEx.Graph.RetryPolicy` for `retryable?:` predicates and defaults.
- `retry: true` enables defaults.

### Timeout

- Per-attempt budget in milliseconds.
- Timeout raises `LangEx.NodeTimeoutError`, which the retry policy can treat as retryable.
- Exhausted timeouts surface as `%LangEx.NodeError{}`.

### on_error

- Invoked after retries are exhausted.
- Return a state update or `%LangEx.Command{}` — that becomes the node result.
- Failures inside the handler propagate.

Cannot combine `:cache` with `:on_error`.

### Cache

- Memoizes successful results by input state (bounded ETS).
- `cache: true` — no TTL; or `cache: [ttl: ms]`.

### Defer

- Fan-in barrier for parallel branches that converge at different depths.
- Deferred node runs only when no other non-deferred nodes are active.

## LLM resilience

Wrap provider calls independently of graph retry:

```elixir
ChatModel.node(model: "gpt-4o", resilient: true)
# or resilient: [max_retries: 3, retry_base_ms: 200, fallback: OtherProvider]
```

`LangEx.LLM.Resilient` retries transient provider failures with backoff / optional fallback.

## Tool errors

`Tool.Node` can convert tool exceptions into error tool messages (`handle_tool_errors: true`) so the LLM can recover. Use `LangEx.Tool.Annotation` to attach recovery guidance.

## Testing tips

- Assert on `{:error, %LangEx.NodeError{node: :x}}` rather than `assert_raise` for node failure paths.
- Leave deliberate routing bugs as raises — they should fail the test suite loudly.
