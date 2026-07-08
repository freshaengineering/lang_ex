defmodule LangEx.LLM.ToolCallingTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.LLM.ChatModel
  alias LangEx.Graph
  alias LangEx.Message
  alias LangEx.Tool
  alias LangEx.Tool.Node, as: ToolNode

  @weather_tool %Tool{
    name: "get_weather",
    description: "Get weather",
    parameters: %{
      type: "object",
      properties: %{location: %{type: "string"}},
      required: ["location"]
    }
  }

  describe "OpenAI tool calling" do
    test "returns tool_calls on AI message" do
      stub(LangEx.LLM.OpenAI, :chat, fn _messages, opts ->
        assert Enum.any?(opts[:tools] || [], &match?(%Tool{name: "get_weather"}, &1))

        call = %Message.ToolCall{
          name: "get_weather",
          id: "call_1",
          args: %{"location" => "London"}
        }

        {:ok, Message.ai(nil, tool_calls: [call])}
      end)

      {:ok, result} =
        LangEx.LLM.OpenAI.chat(
          [Message.human("Weather in London?")],
          tools: [@weather_tool],
          model: "gpt-4o-mini",
          api_key: "test"
        )

      assert %Message.AI{
               content: nil,
               tool_calls: [
                 %Message.ToolCall{name: "get_weather", args: %{"location" => "London"}}
               ]
             } = result
    end
  end

  describe "Gemini tool calling" do
    test "returns tool_calls on AI message" do
      stub(LangEx.LLM.Gemini, :chat, fn _messages, opts ->
        assert Enum.any?(opts[:tools] || [], &match?(%Tool{name: "get_weather"}, &1))
        call = %Message.ToolCall{name: "get_weather", id: nil, args: %{"location" => "Tokyo"}}
        {:ok, Message.ai(nil, tool_calls: [call])}
      end)

      {:ok, result} =
        LangEx.LLM.Gemini.chat(
          [Message.human("Weather in Tokyo?")],
          tools: [@weather_tool],
          model: "gemini-2.5-flash",
          api_key: "test"
        )

      assert %Message.AI{tool_calls: [%Message.ToolCall{name: "get_weather"}]} = result
    end
  end

  describe "Anthropic tool calling" do
    test "returns tool_calls on AI message" do
      stub(LangEx.LLM.Anthropic, :chat, fn _messages, opts ->
        assert Enum.any?(opts[:tools] || [], &match?(%Tool{name: "get_weather"}, &1))
        call = %Message.ToolCall{name: "get_weather", id: "tu_1", args: %{"location" => "Sydney"}}
        {:ok, Message.ai(nil, tool_calls: [call])}
      end)

      {:ok, result} =
        LangEx.LLM.Anthropic.chat(
          [Message.human("Weather in Sydney?")],
          tools: [@weather_tool],
          model: "claude-sonnet-4-20250514",
          api_key: "test"
        )

      assert %Message.AI{tool_calls: [%Message.ToolCall{name: "get_weather"}]} = result
    end
  end

  describe "ToolNode graph integration" do
    test "LLM → ToolNode → LLM loop produces final text response" do
      call_count = :counters.new(1, [:atomics])

      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn messages, _opts ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        has_tool_result = Enum.any?(messages, &match?(%Message.Tool{}, &1))

        case {n, has_tool_result} do
          {0, false} ->
            call = %Message.ToolCall{
              name: "get_weather",
              id: "call_1",
              args: %{"location" => "London"}
            }

            {:ok, Message.ai(nil, tool_calls: [call]), %{input_tokens: 10, output_tokens: 5}}

          {_, true} ->
            {:ok, Message.ai("It's 22 degrees in London."), %{input_tokens: 10, output_tokens: 5}}

          _ ->
            {:ok, Message.ai("Let me check..."), %{input_tokens: 10, output_tokens: 5}}
        end
      end)

      weather_tool_with_fn = %{
        @weather_tool
        | function: fn %{"location" => loc} -> %{"temp" => 22, "city" => loc} end
      }

      graph =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(
          :agent,
          ChatModel.node(model: "gpt-4o-mini", api_key: "test", tools: [weather_tool_with_fn])
        )
        |> Graph.add_node(:tools, ToolNode.node([weather_tool_with_fn]))
        |> Graph.add_conditional_edges(:agent, &ToolNode.tools_condition/1, %{
          tools: :tools,
          __end__: :__end__
        })
        |> Graph.add_edge(:__start__, :agent)
        |> Graph.add_edge(:tools, :agent)
        |> Graph.compile()

      {:ok, result} = LangEx.invoke(graph, %{messages: [Message.human("Weather in London?")]})

      assert List.last(result.messages).content == "It's 22 degrees in London."
    end
  end
end
