# Streaming: consume graph execution as a lazy event stream.
#
# The stream blocks until the next event arrives — slow nodes never
# halt it — and a crashing node surfaces as a `{:done, {:error, ...}}`
# event instead of killing the consumer.
#
# Run: elixir examples/scripts/02_streaming.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

alias LangEx.Graph

graph =
  Graph.new(value: 0)
  |> Graph.add_node(:fetch, fn state ->
    Process.sleep(100)
    %{value: state.value + 1}
  end)
  |> Graph.add_node(:enrich, fn state ->
    Process.sleep(100)
    %{value: state.value * 10}
  end)
  |> Graph.add_edge(:__start__, :fetch)
  |> Graph.add_edge(:fetch, :enrich)
  |> Graph.add_edge(:enrich, :__end__)
  |> Graph.compile(name: :streaming_demo)

graph
|> LangEx.stream(%{value: 1})
|> Enum.each(fn
  {:step_start, step, nodes} -> IO.puts("step #{step} starting: #{inspect(nodes)}")
  {:node_start, node} -> IO.puts("  -> #{node} running...")
  {:node_end, node, update} -> IO.puts("  <- #{node} returned #{inspect(update)}")
  {:step_end, step, state} -> IO.puts("step #{step} done, state: #{inspect(state)}")
  {:done, {:ok, result}} -> IO.puts("finished: #{inspect(result)}")
  {:done, {:error, reason}} -> IO.puts("failed: #{inspect(reason)}")
  _other -> :ok
end)
