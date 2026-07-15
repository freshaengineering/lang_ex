# Custom shared team state, reduced exactly once across a handoff — live.
#
# A two-agent onboarding swarm shares a custom `:checklist` state key (a
# reducer-backed list). The intake agent records a step and hands off to
# the compliance agent, which records another. Because reducer-backed keys
# are seeded at their default inside each member, the list accumulates each
# item exactly once (no double-counting across the handoff).
#
# Requires an API key:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   elixir examples/scripts/22_custom_state_live.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule CustomStateLive do
  alias LangEx.Command
  alias LangEx.Message
  alias LangEx.Prebuilt.Swarm
  alias LangEx.Tool

  @model "claude-haiku-4-5"

  def run do
    request = "Onboard new customer Acme Corp."
    IO.puts("=== Request ===\n#{request}\n")

    {:ok, state} =
      LangEx.invoke(build(), %{messages: [Message.human(request)]})

    IO.puts("=== Final reply ===\n#{List.last(state.messages).content}")
    IO.puts("\n=== Shared checklist (accumulated once per step) ===")
    Enum.each(state.checklist, &IO.puts("  - #{&1}"))
  end

  defp build do
    Swarm.create(
      default_active_agent: :intake,
      state_schema: [checklist: {[], &Kernel.++/2}],
      agents: [
        [
          name: :intake,
          model: @model,
          max_tokens: 300,
          system_prompt:
            "You are the intake agent. First call record_step with step=\"identity verified\". " <>
              "Then transfer to the compliance agent.",
          tools: [record_tool()]
        ],
        [
          name: :compliance,
          model: @model,
          max_tokens: 300,
          system_prompt:
            "You are the compliance agent. First call record_step with step=\"compliance approved\". " <>
              "Then tell the user onboarding is complete.",
          tools: [record_tool()]
        ]
      ]
    )
  end

  defp record_tool do
    %Tool{
      name: "record_step",
      description: "Record a completed onboarding step into the shared checklist.",
      parameters: %{
        type: "object",
        properties: %{step: %{type: "string"}},
        required: ["step"]
      },
      function: fn %{"step" => step} ->
        %Command{update: %{checklist: [step]}}
      end
    }
  end
end

CustomStateLive.run()
