# Parallel supervisor fan-out — fully offline.
#
# A scripted provider stands in for a real LLM so the example runs without
# API keys. On its first turn the supervisor delegates to BOTH specialists
# at once; `parallel: true` runs them concurrently and fans their
# attributed results back in a single step, then the supervisor synthesizes
# a final answer. Swap `ScriptedLLM` for a real `model:` (plus an API key)
# to talk to actual models.
#
# Run: elixir examples/scripts/15_supervisor_parallel.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule ScriptedLLM do
  @moduledoc "Fake provider: the supervisor fans out once, then synthesizes."
  @behaviour LangEx.LLM

  alias LangEx.Message

  @impl true
  def chat(messages, opts) do
    with {:ok, ai, _usage} <- chat_with_usage(messages, opts), do: {:ok, ai}
  end

  @impl true
  def chat_with_usage(messages, _opts), do: messages |> agent() |> respond(messages)

  defp agent(messages) do
    Enum.find_value(messages, fn
      %Message.System{content: "You research." <> _} -> :research
      %Message.System{content: "You calculate." <> _} -> :math
      %Message.System{content: "You are the lead." <> _} -> :lead
      _ -> nil
    end)
  end

  defp respond(:research, _messages),
    do: {:ok, Message.ai("Found 3 relevant sources."), usage()}

  defp respond(:math, _messages), do: {:ok, Message.ai("The total is 42."), usage()}

  defp respond(:lead, messages) do
    messages
    |> both_reported?()
    |> lead_turn()
  end

  defp both_reported?(messages) do
    Enum.any?(messages, &mentions?(&1, "Found 3")) and
      Enum.any?(messages, &mentions?(&1, "total is 42"))
  end

  defp lead_turn(true),
    do: {:ok, Message.ai("Summary: 3 sources reviewed, total is 42."), usage()}

  defp lead_turn(false) do
    calls = [
      %Message.ToolCall{
        name: "transfer_to_research",
        id: "r1",
        args: %{"task_description" => "find sources"}
      },
      %Message.ToolCall{
        name: "transfer_to_math",
        id: "m1",
        args: %{"task_description" => "add the figures"}
      }
    ]

    {:ok, Message.ai(nil, tool_calls: calls), usage()}
  end

  defp mentions?(%{content: content}, text) when is_binary(content),
    do: String.contains?(content, text)

  defp mentions?(_message, _text), do: false

  defp usage, do: %{input_tokens: 20, output_tokens: 6}
end

defmodule ParallelDemo do
  alias LangEx.Message
  alias LangEx.Prebuilt.Supervisor

  def run do
    {:ok, state} =
      build()
      |> LangEx.stream(%{messages: [Message.human("Research and total the figures.")]})
      |> Enum.reduce(nil, &trace/2)

    IO.puts("\nfinal answer: #{List.last(state.messages).content}")
    IO.puts("token usage:  #{inspect(state.llm_usage)}")
  end

  defp trace({:node_start, node}, acc) do
    IO.puts("  ...#{node} started")
    acc
  end

  defp trace({:done, result}, _acc), do: result
  defp trace(_event, acc), do: acc

  defp build do
    Supervisor.create(
      parallel: true,
      provider: ScriptedLLM,
      model: "scripted-1",
      prompt: "You are the lead. Delegate research and math, then summarize.",
      agents: [
        [provider: ScriptedLLM, model: "scripted-1", name: :research, system_prompt: "You research."],
        [provider: ScriptedLLM, model: "scripted-1", name: :math, system_prompt: "You calculate."]
      ]
    )
  end
end

ParallelDemo.run()
