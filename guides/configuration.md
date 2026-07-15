# Configuration

## API keys and provider settings

Resolved in order:

1. Explicit options passed to `ChatModel.node/1` / `provider.chat/2`
2. Application environment (`config :lang_ex, …`)
3. Environment variables

```elixir
# config/runtime.exs
config :lang_ex, :anthropic, api_key: System.get_env("ANTHROPIC_API_KEY")
config :lang_ex, :openai, api_key: System.get_env("OPENAI_API_KEY")
config :lang_ex, :gemini, api_key: System.get_env("GEMINI_API_KEY")
```

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export OPENAI_API_KEY=sk-...
export GEMINI_API_KEY=...
```

Exact keys are provider-module specific; prefer env vars in production and never commit secrets.

## Model → provider resolution

```elixir
ChatModel.node(model: "claude-opus-4-20250514")  # Anthropic
ChatModel.node(model: "gpt-4o")                  # OpenAI
ChatModel.node(model: "gemini-2.0-flash")        # Gemini
ChatModel.node(provider: MyApp.LLM.Groq, model: "llama-3.1-70b")
```

Register custom providers at runtime:

```elixir
LangEx.LLM.Registry.register_provider(:groq, MyApp.LLM.Groq)
LangEx.LLM.Registry.register_prefix("llama-", :groq)
```

## Runtime context

Inject dependencies without capturing them in closures:

```elixir
Graph.add_node(:greet, fn _state, context ->
  %{greeting: "Hello from #{context.provider}!"}
end)

LangEx.invoke(graph, %{}, context: %{provider: "Anthropic"})
```

Arity chooses the call shape:

- Arity 1 — state only
- Arity 2 — `(state, context)`; context is `nil` when you omit `:context`

## Invoke-time knobs

```elixir
LangEx.invoke(graph, input,
  config: [thread_id: "t-1", repo: MyApp.Repo],
  context: %{current_user_id: user.id},
  recursion_limit: 40,
  max_concurrency: 8,
  node_timeout: 15_000,
  durability: :async
)
```

See [Graphs](graphs.md) and [Checkpointing](checkpointing.md) for option semantics.

## Optional dependencies

| Feature | Dependency |
|---|---|
| Redis checkpointer | `{:redix, "~> 1.5"}` |
| Postgres checkpointer / store | `{:postgrex, "~> 0.19"}`, `{:ecto_sql, "~> 3.12"}` |
| OpenTelemetry bridge | `{:opentelemetry_api, "~> 1.2"}`, `{:opentelemetry_telemetry, "~> 1.1"}` |

Modules that need optional deps are compile-time guarded (`Code.ensure_loaded?/1`). If a backend module is “missing,” you forgot the dep — not a runtime surprise.

## Application supervision

LangEx starts its OTP application with your app when it is a dependency. That application owns ETS tables used for caching / registries. You generally do not add LangEx children to your own supervisor for the default setup; Redis/Postgres connections follow your hosting conventions and backend docs.
