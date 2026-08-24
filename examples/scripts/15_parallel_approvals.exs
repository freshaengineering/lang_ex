# Fan-out where every branch pauses for its own approval.
#
# `Send` dispatches one copy of a node per payload. When several copies
# interrupt in the same super-step, each pending question is scoped to
# its own branch — the ID reads "review#Ab3f:0" — so three branches
# produce three separately answerable questions rather than one shared
# one.
#
# A reviewer can therefore approve one refund, reject another, and leave
# the third pending; each branch resumes with the answer meant for it.
#
# With one pending interrupt `invoke` returns the bare payload (see
# 05_human_in_the_loop.exs). With several it returns the full list, each
# entry carrying the branch's `:id`, the `:value` it paused with, and the
# `:entry` (the `%Send{}`) it came from — so a decision can be made from
# the branch's own data rather than by parsing its question.
#
# Run: elixir examples/scripts/15_parallel_approvals.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])
Code.require_file("support/in_memory_checkpointer.exs", __DIR__)

defmodule RefundBatchDemo do
  alias Example.InMemoryCheckpointer
  alias LangEx.Command
  alias LangEx.Graph
  alias LangEx.Interrupt
  alias LangEx.Send

  @config [thread_id: "refund-batch-1"]
  @single_reviewer_limit 500

  @claims [
    %{id: "c-1", customer: "Ada", amount: 40},
    %{id: "c-2", customer: "Grace", amount: 950},
    %{id: "c-3", customer: "Alan", amount: 120}
  ]

  def run do
    graph = build()

    # One super-step fans out to three copies of :review, each pausing.
    {:interrupt, pending, _state} = LangEx.invoke(graph, %{claims: @claims}, config: @config)

    IO.puts("#{length(pending)} claims waiting on a reviewer:")
    Enum.each(pending, &IO.puts("  #{&1.id} -> #{&1.value}"))

    # Answering one branch leaves the others pending.
    {:interrupt, still_pending, _state} =
      LangEx.invoke(graph, %Command{resume: approve_one(pending, "c-1")}, config: @config)

    IO.puts("\nafter approving c-1, #{length(still_pending)} still waiting")

    # Now answer the rest, deciding from each branch's own claim.
    {:ok, result} =
      LangEx.invoke(graph, %Command{resume: decide_all(still_pending)}, config: @config)

    IO.puts("\ndecisions:")
    Enum.each(Enum.sort(result.decisions), &IO.puts("  #{&1}"))
    IO.puts("\npaid out: $#{result.paid}")
  end

  defp approve_one(pending, claim_id) do
    pending
    |> Enum.find(&(&1.entry.state.id == claim_id))
    |> then(&%{&1.id => :approve})
  end

  defp decide_all(pending), do: Map.new(pending, &{&1.id, decide(&1.entry.state)})

  # Anything above the limit needs a second pair of eyes we do not have today.
  defp decide(%{amount: amount}) when amount > @single_reviewer_limit,
    do: {:reject, "over the $#{@single_reviewer_limit} single-reviewer limit"}

  defp decide(_claim), do: :approve

  defp build do
    Graph.new(
      claims: [],
      decisions: {[], &Kernel.++/2},
      paid: {0, &Kernel.+/2}
    )
    |> Graph.add_node(:intake, fn _state -> %{} end)
    |> Graph.add_node(:review, &review/1)
    |> Graph.add_edge(:__start__, :intake)
    |> Graph.add_conditional_edges(:intake, &sends/1, %{review: :review})
    |> Graph.add_edge(:review, :__end__)
    |> Graph.compile(name: :refund_batch, checkpointer: InMemoryCheckpointer)
  end

  defp sends(state), do: Enum.map(state.claims, &%Send{node: :review, state: &1})

  # Each dispatched copy sees its own claim as state.
  defp review(claim) do
    "approve $#{claim.amount} refund for #{claim.customer}?"
    |> Interrupt.interrupt()
    |> settle(claim)
  end

  defp settle(:approve, claim),
    do: %{decisions: ["#{claim.id} approved ($#{claim.amount})"], paid: claim.amount}

  defp settle({:reject, reason}, claim),
    do: %{decisions: ["#{claim.id} rejected — #{reason}"], paid: 0}
end

RefundBatchDemo.run()
