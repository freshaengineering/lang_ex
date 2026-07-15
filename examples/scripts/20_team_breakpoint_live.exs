# Team-level static breakpoint (approval gate before an agent) — live.
#
# A support swarm where the front-line agent may hand off to a `refunds`
# specialist. The team is compiled with `interrupt_before: [:refunds]`, so
# control pauses BEFORE the refunds specialist ever runs — a manager
# approval gate. Approving resumes the specialist; the run then completes.
#
# Requires an API key:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   elixir examples/scripts/20_team_breakpoint_live.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule BreakpointLive do
  alias LangEx.Checkpointer
  alias LangEx.Command
  alias LangEx.Message
  alias LangEx.Prebuilt.Swarm
  alias LangEx.Tool

  @model "claude-haiku-4-5"
  @cfg [thread_id: "refund-approval-1"]

  def run do
    graph = build()

    request = "I was double-charged $80 on order Z-42. Please refund the extra charge."
    IO.puts("=== Customer ===\n#{request}\n")

    graph
    |> LangEx.invoke(%{messages: [Message.human(request)]}, config: @cfg)
    |> handle(graph)
  end

  defp handle({:interrupt, {:interrupt_before, agent}, state}, graph) do
    IO.puts("  ...front-line handled, active agent now: #{state.active_agent}")
    IO.puts("\n⏸  APPROVAL GATE: about to run the #{agent} specialist. Approving...\n")

    {:ok, final} = LangEx.invoke(graph, %Command{resume: true}, config: @cfg)

    IO.puts("=== #{final.active_agent} ===\n#{List.last(final.messages).content}")
  end

  defp handle({:ok, state}, _graph) do
    IO.puts("=== #{state.active_agent} (no handoff) ===\n#{List.last(state.messages).content}")
  end

  defp build do
    Swarm.create(
      checkpointer: Checkpointer.Memory,
      default_active_agent: :frontline,
      interrupt_before: [:refunds],
      agents: [
        [
          name: :frontline,
          model: @model,
          max_tokens: 300,
          system_prompt:
            "You are front-line support. For any refund or billing dispute, immediately " <>
              "transfer to the refunds agent. Do not resolve refunds yourself."
        ],
        [
          name: :refunds,
          model: @model,
          max_tokens: 400,
          system_prompt:
            "You are the refunds specialist. Use issue_refund to process the refund, then " <>
              "confirm to the customer in one sentence.",
          tools: [refund_tool()]
        ]
      ]
    )
  end

  defp refund_tool do
    %Tool{
      name: "issue_refund",
      description: "Issue a refund for an order.",
      parameters: %{
        type: "object",
        properties: %{order_id: %{type: "string"}, amount: %{type: "string"}},
        required: ["order_id", "amount"]
      },
      function: fn %{"order_id" => id, "amount" => amount} ->
        %{order_id: id, refunded: amount, confirmation: "RFND-Z42-01"}
      end
    }
  end
end

BreakpointLive.run()
