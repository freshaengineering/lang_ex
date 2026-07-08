# Tool-calling agent loop with token usage accounting — fully offline.
#
# A scripted provider stands in for a real LLM so the example runs
# without API keys: first it requests a tool call, then it answers.
# Swap `ScriptedLLM` for `model: "claude-opus-4-20250514"` (plus an
# ANTHROPIC_API_KEY) to talk to a real model.
#
# Run: elixir examples/scripts/04_agent_with_tools.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule ScriptedLLM do
  @moduledoc "Fake provider: asks for the weather tool once, then answers."
  @behaviour LangEx.LLM

  alias LangEx.Message

  @impl true
  def chat(messages, opts) do
    with {:ok, ai, _usage} <- chat_with_usage(messages, opts), do: {:ok, ai}
  end

  @impl true
  def chat_with_usage(messages, _opts) do
    messages
    |> Enum.any?(&match?(%Message.Tool{}, &1))
    |> respond()
  end

  defp respond(false) do
    call = %Message.ToolCall{name: "get_weather", id: "call_1", args: %{"city" => "Tokyo"}}
    {:ok, Message.ai(nil, tool_calls: [call]), %{input_tokens: 42, output_tokens: 11}}
  end

  defp respond(true) do
    {:ok, Message.ai("It's 22°C and sunny in Tokyo."), %{input_tokens: 60, output_tokens: 14}}
  end
end

defmodule AgentDemo do
  alias LangEx.Graph
  alias LangEx.LLM.ChatModel
  alias LangEx.Message
  alias LangEx.Tool

  def run do
    {:ok, result} =
      LangEx.invoke(build(), %{messages: [Message.human("Weather in Tokyo?")]})

    IO.puts("answer: #{List.last(result.messages).content}")
    IO.puts("usage:  #{inspect(result.llm_usage)}")
  end

  defp weather_tool do
    %Tool{
      name: "get_weather",
      description: "Get current weather for a city",
      parameters: %{type: "object", properties: %{city: %{type: "string"}}, required: ["city"]},
      function: &fetch_weather/1
    }
  end

  defp fetch_weather(%{"city" => city}), do: %{"city" => city, "temp_c" => 22, "sky" => "sunny"}

  defp build do
    Graph.new(
      messages: {[], &Message.add_messages/2},
      # Declaring this key (with the merge_usage reducer) makes every
      # ChatModel call accumulate its token counts here.
      llm_usage: {%{}, &ChatModel.merge_usage/2}
    )
    |> Graph.add_node(
      :agent,
      ChatModel.node(provider: ScriptedLLM, model: "scripted-1", tools: [weather_tool()])
    )
    |> Graph.add_node(:tools, LangEx.Tool.Node.node([weather_tool()]))
    |> Graph.add_edge(:__start__, :agent)
    |> Graph.add_conditional_edges(:agent, &LangEx.Tool.Node.tools_condition/1, %{
      tools: :tools,
      __end__: :__end__
    })
    |> Graph.add_edge(:tools, :agent)
    |> Graph.compile(name: :weather_agent)
  end
end

AgentDemo.run()
