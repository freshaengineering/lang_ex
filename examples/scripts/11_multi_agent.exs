# Multi-agent swarm: agents hand the conversation to one another — fully offline.
#
# A scripted provider stands in for a real LLM so the example runs
# without API keys: the router transfers to the refunds agent, which
# then answers. Swap `ScriptedLLM` for a real `model:` (plus an API key)
# to talk to actual models.
#
# Run: elixir examples/scripts/11_multi_agent.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule ScriptedLLM do
  @moduledoc "Fake provider: the router hands off, the refunds agent answers."
  @behaviour LangEx.LLM

  alias LangEx.Message

  @impl true
  def chat(messages, opts) do
    with {:ok, ai, _usage} <- chat_with_usage(messages, opts), do: {:ok, ai}
  end

  @impl true
  def chat_with_usage(messages, _opts) do
    messages
    |> agent()
    |> respond()
  end

  defp agent(messages) do
    Enum.find_value(messages, fn
      %Message.System{content: "You handle refunds."} -> :refunds
      %Message.System{content: "You route the user."} -> :router
      _ -> nil
    end)
  end

  defp respond(:router) do
    call = %Message.ToolCall{name: "transfer_to_refunds", id: "handoff_1", args: %{}}
    {:ok, Message.ai(nil, tool_calls: [call]), %{input_tokens: 30, output_tokens: 8}}
  end

  defp respond(:refunds) do
    {:ok, Message.ai("I've started your refund — it lands in 3-5 days."),
     %{input_tokens: 45, output_tokens: 12}}
  end
end

defmodule SwarmDemo do
  alias LangEx.Message
  alias LangEx.Prebuilt.Swarm

  def run do
    {:ok, state} =
      LangEx.invoke(build(), %{messages: [Message.human("I want a refund")]})

    IO.puts("active agent: #{state.active_agent}")
    IO.puts("answer:       #{List.last(state.messages).content}")
  end

  defp build do
    Swarm.create(
      agents: [
        [provider: ScriptedLLM, model: "scripted-1", name: :router, system_prompt: "You route the user."],
        [provider: ScriptedLLM, model: "scripted-1", name: :refunds, system_prompt: "You handle refunds."]
      ],
      default_active_agent: :router
    )
  end
end

SwarmDemo.run()
