defmodule LangEx.PrebuiltTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Message
  alias LangEx.Prebuilt
  alias LangEx.Tool

  describe "agent/1" do
    test "runs the full tool loop and accumulates usage" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn messages, _opts ->
        messages
        |> Enum.any?(&match?(%Message.Tool{}, &1))
        |> scripted_reply()
      end)

      graph =
        Prebuilt.agent(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          system_prompt: "You are a weather bot.",
          tools: [weather_tool()]
        )

      {:ok, result} =
        LangEx.invoke(graph, %{messages: [Message.human("Weather in Tokyo?")]})

      assert %Message.AI{content: "22C and sunny"} = List.last(result.messages)
      assert %{input_tokens: 20, output_tokens: 10} = result.llm_usage
    end

    test "prepends the system prompt exactly once" do
      test_pid = self()

      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn messages, _opts ->
        send(test_pid, {:sent_messages, messages})
        {:ok, Message.ai("hi"), %{input_tokens: 1, output_tokens: 1}}
      end)

      graph =
        Prebuilt.agent(provider: LangEx.LLM.OpenAI, model: "gpt-4o", system_prompt: "Be brief.")

      {:ok, _} = LangEx.invoke(graph, %{messages: [Message.human("Hello")]})

      assert_received {:sent_messages, [%Message.System{content: "Be brief."} | _]}
    end

    test "without tools the graph is a single LLM turn" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("just chat"), %{input_tokens: 1, output_tokens: 1}}
      end)

      graph = Prebuilt.agent(provider: LangEx.LLM.OpenAI, model: "gpt-4o")

      {:ok, result} = LangEx.invoke(graph, %{messages: [Message.human("Hello")]})

      assert [%Message.Human{}, %Message.AI{content: "just chat"}] = result.messages
    end

    test "checkpointer enables interrupt_before breakpoints" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("done"), %{input_tokens: 1, output_tokens: 1}}
      end)

      graph =
        Prebuilt.agent(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          checkpointer: LangEx.Checkpointer.Memory,
          interrupt_before: [:agent]
        )

      config = [thread_id: "prebuilt-bp-1"]

      {:interrupt, {:interrupt_before, :agent}, _state} =
        LangEx.invoke(graph, %{messages: [Message.human("Hello")]}, config: config)

      {:ok, result} = LangEx.invoke(graph, %LangEx.Command{resume: true}, config: config)

      assert %Message.AI{content: "done"} = List.last(result.messages)
    end
  end

  defp weather_tool do
    %Tool{
      name: "get_weather",
      description: "Get weather for a city",
      parameters: %{},
      function: fn _args -> %{"temp" => 22} end
    }
  end

  defp scripted_reply(false) do
    call = %Message.ToolCall{name: "get_weather", id: "c1", args: %{"city" => "Tokyo"}}
    {:ok, Message.ai(nil, tool_calls: [call]), %{input_tokens: 10, output_tokens: 5}}
  end

  defp scripted_reply(true),
    do: {:ok, Message.ai("22C and sunny"), %{input_tokens: 10, output_tokens: 5}}
end
