# Durable execution: a crashed run resumes from where it left off.
#
# Every super-step is checkpointed with the nodes still to run.
# After a crash, invoking the same thread with an empty input `%{}`
# continues from the pending nodes — completed work is not repeated.
#
# Run: elixir examples/scripts/06_crash_recovery.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])
Code.require_file("support/in_memory_checkpointer.exs", __DIR__)

defmodule PipelineDemo do
  alias Example.InMemoryCheckpointer
  alias LangEx.Graph

  @config [thread_id: "nightly-import"]

  def run do
    graph = build()

    # Node failures come back as a structured error, not a raise.
    {:error, %LangEx.NodeError{node: :upload} = error} =
      LangEx.invoke(graph, %{}, config: @config)

    IO.puts("crashed: #{Exception.message(error)}")

    # Flaky dependency is back — same thread, empty input, resumes at :upload.
    {:ok, result} = LangEx.invoke(graph, %{}, config: @config)
    IO.puts("steps run: #{inspect(result.steps)}")
  end

  defp build do
    Graph.new(steps: {[], &Kernel.++/2})
    |> Graph.add_node(:extract, fn _state ->
      IO.puts("extracting (expensive)...")
      %{steps: [:extract]}
    end)
    |> Graph.add_node(:transform, fn _state -> %{steps: [:transform]} end)
    |> Graph.add_node(:upload, &upload/1)
    |> Graph.add_edge(:__start__, :extract)
    |> Graph.add_edge(:extract, :transform)
    |> Graph.add_edge(:transform, :upload)
    |> Graph.add_edge(:upload, :__end__)
    |> Graph.compile(name: :nightly_import, checkpointer: InMemoryCheckpointer)
  end

  # Fails on the first attempt, succeeds on the retry.
  defp upload(_state) do
    :persistent_term.get(:upload_attempted, false) || crash_once()
    %{steps: [:upload]}
  end

  defp crash_once do
    :persistent_term.put(:upload_attempted, true)
    raise "storage unavailable"
  end
end

PipelineDemo.run()
