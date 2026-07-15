# A pre-built agent as a supervisor worker + verbatim forwarding — live.
#
# The supervisor's worker is a *pre-compiled* `LangEx.Prebuilt.agent/1`
# (a calculator with a tool), passed as a `{name, compiled_graph}` pair.
# The supervisor delegates the arithmetic, then uses the `forward_message`
# tool to return the calculator's answer VERBATIM (no paraphrasing) as the
# final response.
#
# Requires an API key:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   elixir examples/scripts/18_prebuilt_worker_forward_live.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule PrebuiltWorkerLive do
  alias LangEx.Message
  alias LangEx.Prebuilt
  alias LangEx.Prebuilt.Supervisor
  alias LangEx.Tool

  @model "claude-haiku-4-5"

  def run do
    IO.puts("=== User ===\nWhat is 128 multiplied by 47?\n")

    {:ok, state} = LangEx.invoke(build(), %{messages: [Message.human("What is 128 multiplied by 47?")]})

    IO.puts("=== Final (forwarded verbatim from the calculator) ===")
    IO.puts(List.last(state.messages).content)
  end

  defp build do
    calculator =
      Prebuilt.agent(
        name: :calculator,
        model: @model,
        max_tokens: 256,
        system_prompt: "You are a calculator. Always use the multiply tool, then state the result.",
        tools: [multiply_tool()]
      )

    Supervisor.create(
      model: @model,
      max_tokens: 256,
      forward_message: true,
      prompt:
        "You coordinate a calculator worker. Delegate the arithmetic to the calculator " <>
          "agent. When it reports back, call forward_message with from=\"calculator\" to " <>
          "return its answer verbatim. Do not rewrite the answer yourself.",
      agents: [{:calculator, calculator}]
    )
  end

  defp multiply_tool do
    %Tool{
      name: "multiply",
      description: "Multiply two integers.",
      parameters: %{
        type: "object",
        properties: %{a: %{type: "integer"}, b: %{type: "integer"}},
        required: ["a", "b"]
      },
      function: fn %{"a" => a, "b" => b} -> %{product: a * b} end
    }
  end
end

PrebuiltWorkerLive.run()
