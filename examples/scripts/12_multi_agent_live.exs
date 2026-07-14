# Live customer-support swarm, powered by a real Anthropic model.
#
# A front-line agent triages the customer and hands off to a Billing or
# Tech specialist. Each specialist has its own tools. The active agent is
# persisted per conversation (via a checkpointer), so a follow-up message
# stays with whoever is handling the customer — and specialists can hand
# off to each other as the conversation shifts.
#
# Requires an API key:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   elixir examples/scripts/12_multi_agent_live.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule SupportTeam do
  alias LangEx.Checkpointer
  alias LangEx.Message
  alias LangEx.Prebuilt.Swarm
  alias LangEx.Tool

  @model "claude-opus-4-8"
  @thread [thread_id: "support-session-1"]

  def run do
    graph = build()

    ask(graph, "Hi — I was charged twice for order A-1234. Can I get a refund?")
    ask(graph, "Thanks! Also, our team dashboard has been down all morning. Is there an outage?")
  end

  defp ask(graph, question) do
    IO.puts("\n=== Customer ===\n#{question}\n")

    graph
    |> LangEx.stream(%{messages: [Message.human(question)]}, config: @thread)
    |> Enum.each(&trace/1)
  end

  defp trace({:node_start, agent}), do: IO.puts("  ...#{agent} is handling it")

  defp trace({:done, {:ok, state}}) do
    IO.puts("\n=== #{state.active_agent} ===\n#{List.last(state.messages).content}")
  end

  defp trace({:done, {:error, reason}}), do: IO.puts("\n[error] #{inspect(reason)}")
  defp trace(_event), do: :ok

  defp build do
    Swarm.create(
      checkpointer: Checkpointer.Memory,
      default_active_agent: :frontline,
      agents: [
        [
          name: :frontline,
          model: @model,
          max_tokens: 1024,
          system_prompt:
            "You are the front-line support agent. Greet briefly, then transfer " <>
              "billing questions (charges, refunds, invoices) to the billing agent " <>
              "and technical questions (outages, logins, bugs) to the tech agent. " <>
              "Do not try to resolve specialist issues yourself."
        ],
        [
          name: :billing,
          model: @model,
          max_tokens: 1024,
          system_prompt:
            "You are the billing specialist. Use lookup_order and issue_refund to " <>
              "resolve charge and refund issues. If the customer raises a technical " <>
              "problem, transfer to the tech agent.",
          tools: [lookup_order_tool(), issue_refund_tool()]
        ],
        [
          name: :tech,
          model: @model,
          max_tokens: 1024,
          system_prompt:
            "You are the technical support specialist. Use check_service_status to " <>
              "investigate outages. If the customer raises a billing issue, transfer " <>
              "to the billing agent.",
          tools: [service_status_tool()]
        ]
      ]
    )
  end

  defp lookup_order_tool do
    %Tool{
      name: "lookup_order",
      description: "Look up an order by its id.",
      parameters: %{
        type: "object",
        properties: %{order_id: %{type: "string"}},
        required: ["order_id"]
      },
      function: fn %{"order_id" => id} ->
        %{order_id: id, amount: "$49.99", charges: 2, status: "duplicate charge detected"}
      end
    }
  end

  defp issue_refund_tool do
    %Tool{
      name: "issue_refund",
      description: "Issue a refund for an order.",
      parameters: %{
        type: "object",
        properties: %{order_id: %{type: "string"}, amount: %{type: "string"}},
        required: ["order_id", "amount"]
      },
      function: fn %{"order_id" => id, "amount" => amount} ->
        %{order_id: id, refunded: amount, confirmation: "RFND-2026-0714", eta_days: 5}
      end
    }
  end

  defp service_status_tool do
    %Tool{
      name: "check_service_status",
      description: "Check the current status of a service.",
      parameters: %{
        type: "object",
        properties: %{service: %{type: "string"}},
        required: ["service"]
      },
      function: fn %{"service" => service} ->
        %{service: service, status: "degraded", incident: "INC-4821", eta_minutes: 30}
      end
    }
  end
end

SupportTeam.run()
