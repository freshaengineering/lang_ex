# In-member human-in-the-loop + token streaming, powered by a real model.
#
# A single-agent support team whose agent must get human approval before it
# replies. The approval gate is an in-member `:pre_model_hook` that calls
# `LangEx.Interrupt.interrupt/1` — so the whole team pauses mid-member and
# resumes at the team level with `%LangEx.Command{resume: ...}`. On resume
# the reply is streamed token-by-token.
#
# Requires an API key:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   elixir examples/scripts/16_in_member_hitl_live.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule HitlDemo do
  alias LangEx.Checkpointer
  alias LangEx.Command
  alias LangEx.Interrupt
  alias LangEx.Message
  alias LangEx.Prebuilt.Swarm

  @model "claude-haiku-4-5"
  @thread [thread_id: "hitl-session-1"]

  def run do
    graph = build()

    IO.puts("=== Customer ===\nMy order never arrived. What can you do?\n")

    {:interrupt, prompt, _paused} =
      LangEx.invoke(graph, %{messages: [Message.human("My order never arrived. What can you do?")]},
        config: @thread
      )

    IO.puts("[paused for approval] #{prompt}")
    IO.puts("[human] approving...\n")

    IO.write("=== Agent (streaming) ===\n")

    final =
      graph
      |> LangEx.stream(%Command{resume: :approved}, config: @thread, modes: [:messages, :updates])
      |> Enum.reduce(nil, &handle_event/2)

    IO.puts("\n\n[done] final state active agent: #{final.active_agent}")
  end

  defp handle_event({:message_delta, %{text: text}}, acc) do
    IO.write(text)
    acc
  end

  defp handle_event({:done, {:ok, state}}, _acc), do: state
  defp handle_event(_event, acc), do: acc

  defp build do
    Swarm.create(
      checkpointer: Checkpointer.Memory,
      default_active_agent: :support,
      agents: [
        [
          name: :support,
          model: @model,
          max_tokens: 512,
          system_prompt:
            "You are a concise customer support agent. Apologize briefly and offer " <>
              "a concrete next step (reshipment or refund).",
          pre_model_hook: fn messages ->
            Interrupt.interrupt("Approve sending a reply to this customer?")
            messages
          end
        ]
      ]
    )
  end
end

HitlDemo.run()
