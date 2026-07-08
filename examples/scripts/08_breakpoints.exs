# Static breakpoints: pause before a risky node without touching its code.
#
# `interrupt_before: [:apply]` is set at compile time — no interrupt
# call inside the node. The graph pauses when execution reaches the
# node; resuming with any Command value runs it.
#
# Run: elixir examples/scripts/08_breakpoints.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])
Code.require_file("support/in_memory_checkpointer.exs", __DIR__)

defmodule DeployDemo do
  alias Example.InMemoryCheckpointer
  alias LangEx.Command
  alias LangEx.Graph

  @config [thread_id: "deploy-42"]

  def run do
    graph = build()

    {:interrupt, {:interrupt_before, :apply}, state} =
      LangEx.invoke(graph, %{change: "scale api-gateway to 6 pods"}, config: @config)

    IO.puts("paused before :apply")
    IO.puts("  plan: #{state.plan}")

    # Operator reviewed the plan — continue.
    {:ok, result} = LangEx.invoke(graph, %Command{resume: :approved}, config: @config)
    IO.puts(result.outcome)
  end

  defp build do
    Graph.new(change: nil, plan: nil, outcome: nil)
    |> Graph.add_node(:plan, fn state -> %{plan: "will #{state.change}"} end)
    |> Graph.add_node(:apply, fn state -> %{outcome: "applied: #{state.plan}"} end)
    |> Graph.add_edge(:__start__, :plan)
    |> Graph.add_edge(:plan, :apply)
    |> Graph.add_edge(:apply, :__end__)
    |> Graph.compile(
      name: :deployer,
      checkpointer: InMemoryCheckpointer,
      interrupt_before: [:apply]
    )
  end
end

DeployDemo.run()
