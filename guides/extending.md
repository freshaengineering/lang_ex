# Extending LangEx

LangEx is built around behaviours. Swap providers, persistence, and memory without forking the engine.

## Custom LLM provider

Implement `LangEx.LLM`:

```elixir
defmodule MyApp.LLM.Groq do
  @behaviour LangEx.LLM

  @impl true
  def chat(messages, opts) do
    # Call Groq HTTP API, map to LangEx.Message.AI
    {:ok, LangEx.Message.ai("…")}
  end

  # Optional — enables usage telemetry / llm_usage accumulation
  @impl true
  def chat_with_usage(messages, opts) do
    with {:ok, msg} <- chat(messages, opts) do
      {:ok, msg, %{input_tokens: 10, output_tokens: 20}}
    end
  end
end

LangEx.LLM.Registry.register_provider(:groq, MyApp.LLM.Groq)
LangEx.LLM.Registry.register_prefix("llama-", :groq)
```

Required: `chat/2`. Recommended: `chat_with_usage/2`.

## Custom checkpointer

Implement `LangEx.Checkpointer`:

```elixir
defmodule MyApp.Checkpointer.S3 do
  @behaviour LangEx.Checkpointer

  @impl true
  def save(config, checkpoint), do: …

  @impl true
  def load(config), do: …   # {:ok, cp} | :none | {:error, _}

  @impl true
  def list(config, opts), do: …

  @impl true
  def delete_thread(config), do: …
end
```

Then:

```elixir
Graph.compile(builder, checkpointer: MyApp.Checkpointer.S3)
```

**Must:** persist `next_nodes` losslessly — entries may be atoms **or** `%LangEx.Send{}`. Use `LangEx.Checkpoint.Serializer` as a reference. See `examples/scripts/support/in_memory_checkpointer.exs` for a ~50-line Agent-backed template.

Optional deps should wrap modules:

```elixir
if Code.ensure_loaded?(ExAws) do
  defmodule MyApp.Checkpointer.S3 do
    …
  end
end
```

## Custom store

Implement `LangEx.Store` (`get/3`, `put/4`, `delete/3`, `search/3`) and attach at compile:

```elixir
Graph.compile(builder, store: {MyApp.Store.Redis, url: url})
```

## Custom nodes (no behaviour needed)

Most extension is just functions:

```elixir
def my_retriever(state, context) do
  docs = context.repo.search(state.query)
  %{documents: docs}
end

Graph.add_node(g, :retrieve, &my_retriever/2)
```

Prefer small, testable node modules over megafunctions.

## Contributing patterns

When adding modules to LangEx itself:

- Module path mirrors `lib/` (`LangEx.Foo.Bar` → `lib/lang_ex/foo/bar.ex`)
- Public functions get `@spec` and `@doc`
- Internal helpers get `@moduledoc false`
- Tests mirror `lib/` under `test/`
