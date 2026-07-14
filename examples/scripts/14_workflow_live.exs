# Live end-to-end workflow, powered by a real Anthropic model.
#
# A multi-agent team is embedded as one step of a larger graph that also
# does Command-based routing, human-in-the-loop approval, long-term
# memory, and durable persistence. It shows how the multi-agent prebuilts
# compose with the rest of LangEx:
#
#   team (swarm) -> risk gate (Command goto) -> human approval (interrupt)
#                -> fulfill (store) -> end
#
# Requires an API key:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   elixir examples/scripts/14_workflow_live.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule Helpdesk do
  alias LangEx.Checkpointer
  alias LangEx.Command
  alias LangEx.Graph
  alias LangEx.Interrupt
  alias LangEx.Message
  alias LangEx.Prebuilt.Swarm
  alias LangEx.Store
  alias LangEx.Tool

  @model "claude-opus-4-8"
  @cfg [thread_id: "ticket-9001"]

  def run do
    Store.ETS.clear()
    graph = build()
    context = %{approver: "on-call SRE (Dana)"}

    request =
      "I'm locked out of my admin account (admin@acme.com) and need the admin password " <>
        "reset urgently so I can restore production access."

    IO.puts("USER: #{request}\n")

    graph
    |> LangEx.stream(%{messages: [Message.human(request)]}, config: @cfg, context: context)
    |> Enum.reduce(nil, &observe/2)
    |> resume(graph, context)

    IO.puts("\n[persisted ticket] #{inspect(Store.ETS.search([], ["tickets"]))}")
  end

  defp observe({:node_start, node}, acc), do: (IO.puts("  » #{node}"); acc)
  defp observe({:interrupt, question}, _acc), do: {:interrupt, question}
  defp observe({:done, {:ok, state}}, _acc), do: {:done, state}
  defp observe({:done, {:error, reason}}, _acc), do: (IO.puts("  [error] #{inspect(reason)}"); :error)
  defp observe(_event, acc), do: acc

  defp resume({:interrupt, question}, graph, context) do
    IO.puts("\n⏸  HUMAN APPROVAL NEEDED:\n#{question}\n(approving)\n")
    {:ok, final} = LangEx.invoke(graph, %Command{resume: true}, config: @cfg, context: context)
    IO.puts("✅ #{List.last(final.messages).content}")
  end

  defp resume({:done, state}, _graph, _context),
    do: IO.puts("✅ (no approval needed) #{List.last(state.messages).content}")

  defp resume(_other, _graph, _context), do: :ok

  defp build do
    Graph.new(
      messages: {[], &Message.add_messages/2},
      active_agent: :triage,
      risk: nil,
      approved: nil
    )
    |> Graph.add_node(:team, &run_team/1)
    |> Graph.add_node(:assess, &assess/2)
    |> Graph.add_node(:approval, &approval/2)
    |> Graph.add_node(:fulfill, &fulfill/1)
    |> Graph.add_edge(:__start__, :team)
    |> Graph.add_edge(:team, :assess)
    |> Graph.add_edge(:approval, :fulfill)
    |> Graph.add_edge(:fulfill, :__end__)
    |> Graph.compile(checkpointer: Checkpointer.Memory, store: Store.ETS, warn_unreachable: false)
  end

  # Step 1: run a support swarm fresh, contributing only its new messages.
  defp run_team(state) do
    {:ok, result} = LangEx.invoke(support_team(), %{messages: state.messages})
    %{messages: Enum.drop(result.messages, length(state.messages))}
  end

  defp support_team do
    Swarm.create(
      default_active_agent: :triage,
      agents: [
        [name: :triage, model: @model, max_tokens: 500,
         system_prompt: "Front-line IT triage. Transfer account/access issues to the it_specialist."],
        [name: :it_specialist, model: @model, max_tokens: 600,
         system_prompt:
           "IT specialist. Use lookup_user to inspect the account, then state the single concrete " <>
             "remediation action you propose in one sentence.",
         tools: [lookup_tool()]]
      ]
    )
  end

  defp lookup_tool do
    %Tool{name: "lookup_user", description: "Look up an account by email.",
      parameters: %{type: "object", properties: %{email: %{type: "string"}}, required: ["email"]},
      function: fn %{"email" => e} -> %{email: e, role: "admin", status: "locked", failed_logins: 5} end}
  end

  # Step 2: risk gate — routes via Command goto based on the proposed action.
  defp assess(state, context) do
    proposal = state.messages |> last_proposal() |> String.downcase()
    high? = String.contains?(proposal, "admin") or String.contains?(proposal, "password")
    IO.puts("    risk gate (approver: #{context.approver}) -> #{if high?, do: "HIGH", else: "low"}")
    route(high?)
  end

  defp route(true), do: %Command{goto: :approval, update: %{risk: :high}}
  defp route(false), do: %Command{goto: :fulfill, update: %{risk: :low}}

  # Step 3: human-in-the-loop approval (interrupts; uses runtime context).
  defp approval(state, context) do
    %{approved: Interrupt.interrupt("[#{context.approver}] Approve HIGH-RISK action?\n#{last_proposal(state.messages)}")}
  end

  # Step 4: fulfill and persist the resolution to long-term store.
  defp fulfill(state) do
    resolution = "Resolved (risk=#{state.risk}, approved=#{inspect(state.approved)}): #{last_proposal(state.messages)}"
    :ok = Store.put(["tickets"], "TICK-9001", resolution)
    %{messages: [Message.ai("Ticket TICK-9001 closed. #{resolution}")]}
  end

  defp last_proposal(messages), do: messages |> Enum.reverse() |> Enum.find_value("", &proposal_text/1)

  defp proposal_text(%Message.AI{content: c}) when is_binary(c) and c != "", do: c
  defp proposal_text(%Message.Human{content: c}) when is_binary(c) and c != "", do: c
  defp proposal_text(_message), do: nil
end

Helpdesk.run()
