# Live multi-agent supervisor team, powered by a real Anthropic model.
#
# A coordinator delegates to two specialists — a math agent and a weather
# agent — each with its own tool. The coordinator hands off with
# `transfer_to_<agent>` tools, the workers do their work and return, and
# the coordinator gives a final combined answer.
#
# Requires an API key:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   elixir examples/scripts/12_multi_agent_live.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule LiveTeam do
  alias LangEx.Message
  alias LangEx.Prebuilt.Supervisor
  alias LangEx.Tool

  @model "claude-opus-4-8"

  def run do
    graph = build()
    question = "What is a 18% tip on an 84 dollar bill, and what's the weather in Tokyo?"

    IO.puts("User: #{question}\n")

    graph
    |> LangEx.stream(%{messages: [Message.human(question)]})
    |> Enum.each(&trace/1)
  end

  defp trace({:node_start, node}), do: IO.puts("  -> #{node} working...")
  defp trace({:node_end, node, _update}), do: IO.puts("  <- #{node} done")

  defp trace({:done, {:ok, state}}) do
    IO.puts("\nFinal answer:\n#{List.last(state.messages).content}")
    IO.puts("\nToken usage: #{inspect(state.llm_usage)}")
  end

  defp trace({:done, {:error, reason}}), do: IO.puts("\nRun error: #{inspect(reason)}")
  defp trace(_event), do: :ok

  defp build do
    Supervisor.create(
      model: @model,
      max_tokens: 1024,
      prompt:
        "You coordinate two specialists: a `math` agent and a `weather` agent. " <>
          "Delegate to exactly ONE specialist at a time by calling a single " <>
          "transfer tool, then wait for the result before delegating again. " <>
          "Delegate math questions to the math agent and weather questions to " <>
          "the weather agent. Once both have answered, reply to the user with a " <>
          "single combined summary.",
      agents: [
        [
          name: :math,
          model: @model,
          max_tokens: 1024,
          system_prompt: "You are a math specialist. Use the calculate tool for arithmetic.",
          tools: [calculate_tool()]
        ],
        [
          name: :weather,
          model: @model,
          max_tokens: 1024,
          system_prompt: "You are a weather specialist. Use the get_weather tool.",
          tools: [weather_tool()]
        ]
      ]
    )
  end

  defp calculate_tool do
    %Tool{
      name: "calculate",
      description: "Evaluate a simple arithmetic operation on two numbers.",
      parameters: %{
        type: "object",
        properties: %{
          a: %{type: "number"},
          op: %{type: "string", enum: ["+", "-", "*", "/"]},
          b: %{type: "number"}
        },
        required: ["a", "op", "b"]
      },
      function: fn %{"a" => a, "op" => op, "b" => b} -> %{result: calc(a, op, b)} end
    }
  end

  defp calc(a, "+", b), do: a + b
  defp calc(a, "-", b), do: a - b
  defp calc(a, "*", b), do: a * b
  defp calc(_a, "/", 0), do: "undefined (division by zero)"
  defp calc(a, "/", b), do: a / b

  defp weather_tool do
    %Tool{
      name: "get_weather",
      description: "Get the current weather for a city.",
      parameters: %{
        type: "object",
        properties: %{city: %{type: "string"}},
        required: ["city"]
      },
      function: fn %{"city" => city} -> %{city: city, temp_c: 22, sky: "clear"} end
    }
  end
end

LiveTeam.run()
