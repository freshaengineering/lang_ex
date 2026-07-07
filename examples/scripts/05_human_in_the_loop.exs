# Human-in-the-loop: pause with interrupt/1, resume with Command.
#
# A node may interrupt several times — each call site gets a stable ID
# ("node:0", "node:1"), so you can answer one question at a time or
# several at once with an id-addressed map.
#
# Run: elixir examples/scripts/05_human_in_the_loop.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])
Code.require_file("support/in_memory_checkpointer.exs", __DIR__)

defmodule OnboardingDemo do
  alias Example.InMemoryCheckpointer
  alias LangEx.Command
  alias LangEx.Graph
  alias LangEx.Interrupt

  @config [thread_id: "onboarding-1"]

  def run do
    graph = build()

    # First run pauses at the first unanswered question.
    {:interrupt, question, _state} = LangEx.invoke(graph, %{}, config: @config)
    IO.puts("paused: #{question}")

    # Resuming re-runs the node; answered interrupts return instantly,
    # the next unanswered one pauses again.
    {:interrupt, question, _state} =
      LangEx.invoke(graph, %Command{resume: "Ada Lovelace"}, config: @config)

    IO.puts("paused: #{question}")

    {:ok, result} = LangEx.invoke(graph, %Command{resume: "ada@example.com"}, config: @config)
    IO.puts("done:   #{result.summary}\n")

    # Or answer everything in one shot with an id-addressed map.
    {:interrupt, _question, _state} =
      LangEx.invoke(graph, %{}, config: [thread_id: "onboarding-2"])

    {:ok, result} =
      LangEx.invoke(
        graph,
        %Command{resume: %{"collect:0" => "Grace Hopper", "collect:1" => "grace@example.com"}},
        config: [thread_id: "onboarding-2"]
      )

    IO.puts("done:   #{result.summary}")
  end

  defp build do
    Graph.new(summary: nil)
    |> Graph.add_node(:collect, fn _state ->
      name = Interrupt.interrupt("What is your name?")
      email = Interrupt.interrupt("What is your email?")
      %{summary: "registered #{name} <#{email}>"}
    end)
    |> Graph.add_edge(:__start__, :collect)
    |> Graph.add_edge(:collect, :__end__)
    |> Graph.compile(name: :onboarding, checkpointer: InMemoryCheckpointer)
  end
end

OnboardingDemo.run()
