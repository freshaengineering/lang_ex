defmodule LangEx.Middleware.ToolSelectorTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Message
  alias LangEx.Middleware.ToolSelector
  alias LangEx.Prebuilt
  alias LangEx.Tool

  describe "wrap_model_call" do
    test "narrows a large tool set before the main model call" do
      test_pid = self()

      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, opts ->
        opts[:tools]
        |> Enum.map(& &1.name)
        |> respond(test_pid)
      end)

      graph =
        Prebuilt.agent(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          tools: [tool("logs"), tool("metrics"), tool("traces")],
          middleware: [
            ToolSelector.new(provider: LangEx.LLM.OpenAI, model: "gpt-4o-mini", max_tools: 1)
          ]
        )

      {:ok, _result} = LangEx.invoke(graph, %{messages: [Message.human("check logs")]})

      assert_received {:main_tools, ["logs"]}
    end

    test "leaves the tool set intact below the threshold" do
      test_pid = self()

      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, opts ->
        send(test_pid, {:main_tools, Enum.map(opts[:tools], & &1.name)})
        {:ok, Message.ai("ok"), %{input_tokens: 1, output_tokens: 1}}
      end)

      graph =
        Prebuilt.agent(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          tools: [tool("logs"), tool("metrics")],
          middleware: [
            ToolSelector.new(provider: LangEx.LLM.OpenAI, model: "gpt-4o-mini", max_tools: 5)
          ]
        )

      {:ok, _result} = LangEx.invoke(graph, %{messages: [Message.human("hi")]})

      assert_received {:main_tools, ["logs", "metrics"]}
    end
  end

  defp respond(["respond"], _test_pid) do
    call = %Message.ToolCall{name: "respond", id: "s1", args: %{"tools" => ["logs"]}}
    {:ok, Message.ai(nil, tool_calls: [call]), %{input_tokens: 1, output_tokens: 1}}
  end

  defp respond(names, test_pid) do
    send(test_pid, {:main_tools, names})
    {:ok, Message.ai("ok"), %{input_tokens: 1, output_tokens: 1}}
  end

  defp tool(name), do: %Tool{name: name, description: "the #{name} tool", parameters: %{}}
end
