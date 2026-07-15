# Supervisor with structured final output (`response_format`) — live.
#
# A support triage lead consults a policy worker, answers the customer, and
# then a final structured step decodes the outcome into a typed
# `:structured_response` (category / priority / refund_eligible) that a
# downstream system could act on — while the human-readable reply stays in
# the transcript.
#
# Requires an API key:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   elixir examples/scripts/19_structured_output_live.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule StructuredLive do
  alias LangEx.Message
  alias LangEx.Prebuilt.Supervisor
  alias LangEx.Tool

  @model "claude-haiku-4-5"

  @ticket "I was charged twice for order A-1234 last week and I'm really frustrated. " <>
            "I want my money back today."

  def run do
    IO.puts("=== Ticket ===\n#{@ticket}\n")

    {:ok, state} = LangEx.invoke(build(), %{messages: [Message.human(@ticket)]})

    IO.puts("=== Human-readable reply ===")
    IO.puts(reply(state.messages))

    IO.puts("\n=== Structured outcome (for downstream systems) ===")
    IO.inspect(state.structured_response, pretty: true)
  end

  # `response_format` appends the decoded JSON as the final assistant
  # message, so the human-readable prose is the AI reply just before it.
  defp reply(messages) do
    messages
    |> Enum.drop(-1)
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %Message.AI{content: c} when is_binary(c) and c != "" -> c
      _ -> nil
    end)
  end

  defp build do
    Supervisor.create(
      model: @model,
      max_tokens: 512,
      prompt:
        "You are a support triage lead. Consult the policy agent about the refund " <>
          "policy, then write a brief empathetic reply to the customer.",
      response_format: %{
        type: "object",
        properties: %{
          category: %{type: "string", description: "billing, technical, or other"},
          priority: %{type: "string", description: "low, medium, or high"},
          refund_eligible: %{type: "boolean"}
        },
        required: ["category", "priority", "refund_eligible"]
      },
      agents: [
        [
          name: :policy,
          model: @model,
          max_tokens: 256,
          system_prompt:
            "You are the refunds policy expert. Duplicate charges are always refundable. " <>
              "State the policy briefly.",
          tools: [policy_tool()]
        ]
      ]
    )
  end

  defp policy_tool do
    %Tool{
      name: "lookup_policy",
      description: "Look up the refund policy for a scenario.",
      parameters: %{
        type: "object",
        properties: %{scenario: %{type: "string"}},
        required: ["scenario"]
      },
      function: fn %{"scenario" => scenario} ->
        %{scenario: scenario, refundable: true, sla_days: 5, requires_approval: false}
      end
    }
  end
end

StructuredLive.run()
