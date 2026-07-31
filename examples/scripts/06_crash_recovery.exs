# Durable execution: a crashed run resumes from where it left off.
#
# Every super-step is checkpointed with the nodes still to run. After a
# crash, invoking the same thread with an empty input `%{}` continues from
# the pending nodes — completed work is not repeated.
#
# The second act is finer-grained. When several nodes run in parallel and
# one fails, the ones that already finished are not re-run either: each
# task's result is journaled as it completes, so a retry replays those and
# only re-executes what actually failed. This matters when the tasks
# beside the failure charge a card or call an API.
#
# Run: elixir examples/scripts/06_crash_recovery.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])
Code.require_file("support/in_memory_checkpointer.exs", __DIR__)

# A failing node logs a crash report; muting the logger keeps this
# script's output readable.
Logger.configure(level: :none)

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

defmodule CheckoutDemo do
  @moduledoc """
  Three effects run in parallel; one fails. Uses the built-in
  `LangEx.Checkpointer.Memory` because journaling task results is an
  optional part of the behaviour that the example template leaves out —
  a backend without it falls back to re-running the whole step.
  """

  alias LangEx.Checkpointer.Memory
  alias LangEx.Graph

  @config [thread_id: "checkout-9"]

  def run do
    graph = build()

    {:error, %LangEx.NodeError{node: :notify}} = LangEx.invoke(graph, %{}, config: @config)
    IO.puts("\nnotify failed; card and stock had already gone through")

    {:ok, result} = LangEx.invoke(graph, %{}, config: @config)

    IO.puts("order: #{inspect(Enum.sort(result.done))}")
    IO.puts("executions per task: #{inspect(executions())}")
    IO.puts("the card was charged #{counter(:charge_card)} time(s), not twice")
  end

  defp build do
    Graph.new(done: {[], &Kernel.++/2}, settled: false)
    |> Graph.add_node(:checkout, fn _state -> %{} end)
    |> Graph.add_node(:charge_card, &effect(&1, :charge_card))
    |> Graph.add_node(:reserve_stock, &effect(&1, :reserve_stock))
    |> Graph.add_node(:notify, &notify/1)
    |> Graph.add_node(:settle, fn _state -> %{settled: true} end)
    |> Graph.add_edge(:__start__, :checkout)
    |> Graph.add_edge(:checkout, :charge_card)
    |> Graph.add_edge(:checkout, :reserve_stock)
    |> Graph.add_edge(:checkout, :notify)
    |> Graph.add_edge(:charge_card, :settle)
    |> Graph.add_edge(:reserve_stock, :settle)
    |> Graph.add_edge(:notify, :settle)
    |> Graph.add_edge(:settle, :__end__)
    |> Graph.compile(name: :checkout, checkpointer: Memory)
  end

  defp effect(_state, name) do
    bump(name)
    %{done: [name]}
  end

  # The email provider is down the first time round.
  defp notify(state) do
    bump(:notify)
    :notify |> counter() |> flake()
    effect(state, :notified)
  end

  defp flake(1), do: raise("smtp connection refused")
  defp flake(_later), do: :ok

  defp executions,
    do: Map.new([:charge_card, :reserve_stock, :notify], &{&1, counter(&1)})

  defp bump(name), do: :persistent_term.put(name, counter(name) + 1)
  defp counter(name), do: :persistent_term.get(name, 0)
end

PipelineDemo.run()
CheckoutDemo.run()
