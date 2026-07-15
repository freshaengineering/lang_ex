# Streaming

`LangEx.stream/3` returns a **lazy Elixir `Stream`** of execution events. Consume it with `Enum`, `Stream`, Phoenix Channels, LiveView, or SSE — no special adapter required.

## Basic usage

```elixir
graph
|> LangEx.stream(%{value: 0}, config: [thread_id: "t-1"])
|> Enum.each(fn
  {:node_start, name} -> IO.puts("→ #{name}")
  {:node_end, name, _update} -> IO.puts("← #{name}")
  {:step, n} -> IO.puts("super-step #{n}")
  {:done, {:ok, result}} -> IO.inspect(result, label: "final")
  {:done, {:interrupt, payload, _}} -> IO.puts("paused: #{inspect(payload)}")
  {:done, {:error, err}} -> IO.puts("failed: #{inspect(err)}")
  other -> IO.inspect(other)
end)
```

The stream always terminates with `{:done, outcome}` where `outcome` mirrors `invoke/3` (`{:ok, _}` | `{:interrupt, _, _}` | `{:error, _}`).

## Why a Stream?

- **Backpressure-friendly** — consumers pull events; nothing buffers unbounded by default.
- **Composable** — `Stream.filter/2`, `Stream.map/2`, `Stream.take_while/2`.
- **BEAM-native** — same abstraction LiveView and Broadway already understand.

## Token / delta streaming

When the provider supports it (notably Anthropic SSE), ChatModel can emit token deltas via callbacks attached in LLM opts. Graph-level stream events remain about **execution structure** (node/step lifecycle); pair them with provider streaming if you need character-level UX.

Wire `[:lang_ex, :llm, :chat, …]` telemetry for usage and latency alongside the stream (see [Observability](observability.md)).

## LiveView sketch

```elixir
def handle_event("ask", %{"q" => q}, socket) do
  pid = self()

  Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
    graph
    |> LangEx.stream(%{messages: [Message.human(q)]}, config: [thread_id: socket.assigns.thread_id])
    |> Enum.each(&send(pid, {:lang_ex, &1}))
  end)

  {:noreply, socket}
end

def handle_info({:lang_ex, {:node_end, :agent, update}}, socket) do
  {:noreply, stream_insert(socket, :events, update)}
end

def handle_info({:lang_ex, {:done, {:ok, state}}}, socket) do
  {:noreply, assign(socket, :answer, List.last(state.messages))}
end
```

Prefer a supervised task so disconnects do not leave orphaned work unmonitored.

## Offline demo

```bash
elixir examples/scripts/02_streaming.exs
```
