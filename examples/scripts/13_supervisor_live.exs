# Live supervisor team, powered by a real Anthropic model.
#
# An incident commander delegates to three specialists — diagnostics,
# runbook, and comms — one at a time. Each worker runs on a task-focused
# view of the conversation and reports back an attributed result, so the
# commander can synthesize a final incident summary from their findings.
#
# Requires an API key:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   elixir examples/scripts/13_supervisor_live.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule IncidentTeam do
  alias LangEx.Message
  alias LangEx.Prebuilt.Supervisor
  alias LangEx.Tool

  @model "claude-opus-4-8"

  def run do
    graph = build()

    request =
      "The checkout service is throwing 500 errors in production. Investigate the metrics, " <>
        "find the relevant runbook, post a customer-facing status update, then give me a " <>
        "concise incident summary with root cause and next steps."

    IO.puts("INCIDENT: #{request}\n")

    graph
    |> LangEx.stream(%{messages: [Message.human(request)]})
    |> Enum.each(&trace/1)
  end

  defp trace({:node_start, :supervisor}), do: IO.puts("  • commander is deciding")
  defp trace({:node_start, agent}), do: IO.puts("  → delegated to #{agent}")

  defp trace({:done, {:ok, state}}) do
    IO.puts("\nINCIDENT SUMMARY:\n#{List.last(state.messages).content}")
    IO.puts("\ntokens: #{inspect(state.llm_usage)}")
  end

  defp trace({:done, {:error, reason}}), do: IO.puts("\n[error] #{inspect(reason)}")
  defp trace(_event), do: :ok

  defp build do
    Supervisor.create(
      model: @model,
      max_tokens: 1200,
      output_mode: :last_message,
      prompt:
        "You are the incident commander. Delegate to ONE specialist at a time and wait for " <>
          "the result: `diagnostics` (metrics), `runbook` (mitigation steps), `comms` (status page). " <>
          "Once you have what you need, write a concise incident summary with root cause and next steps.",
      agents: [
        [name: :diagnostics, model: @model, max_tokens: 800,
         system_prompt: "You are the diagnostics specialist. Use query_metrics to inspect a service and report what you find.",
         tools: [metrics_tool()]],
        [name: :runbook, model: @model, max_tokens: 800,
         system_prompt: "You are the SRE runbook specialist. Use search_runbook to find mitigation steps and report them.",
         tools: [runbook_tool()]],
        [name: :comms, model: @model, max_tokens: 800,
         system_prompt: "You are the communications specialist. Use post_status to publish a status update, then confirm it.",
         tools: [status_tool()]]
      ]
    )
  end

  defp metrics_tool do
    %Tool{name: "query_metrics", description: "Query live metrics for a service.",
      parameters: %{type: "object", properties: %{service: %{type: "string"}}, required: ["service"]},
      function: fn %{"service" => s} ->
        %{service: s, error_rate: "38%", p99_latency_ms: 4200, cpu: "41%",
          recent_deploy: "v2.7.1 deployed 12m ago", db_pool: "exhausted"}
      end}
  end

  defp runbook_tool do
    %Tool{name: "search_runbook", description: "Find a runbook for a symptom.",
      parameters: %{type: "object", properties: %{symptom: %{type: "string"}}, required: ["symptom"]},
      function: fn %{"symptom" => sym} ->
        %{symptom: sym, runbook: "RB-DB-POOL",
          steps: ["Roll back the most recent deploy", "Increase DB pool size to 50", "Verify error rate < 1%"]}
      end}
  end

  defp status_tool do
    %Tool{name: "post_status", description: "Publish a status-page update.",
      parameters: %{type: "object", properties: %{message: %{type: "string"}}, required: ["message"]},
      function: fn %{"message" => m} ->
        %{posted: true, url: "status.example.com/incidents/INC-4821", message: m}
      end}
  end
end

IncidentTeam.run()
