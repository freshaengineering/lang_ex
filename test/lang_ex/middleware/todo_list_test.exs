defmodule LangEx.Middleware.TodoListTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Message
  alias LangEx.Middleware.TodoList
  alias LangEx.Prebuilt
  alias LangEx.Tool

  describe "write_todos tool" do
    test "records the plan into graph state" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn messages, _opts ->
        messages
        |> Enum.any?(&match?(%Message.Tool{}, &1))
        |> reply()
      end)

      graph =
        Prebuilt.agent(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          middleware: [TodoList.new()]
        )

      {:ok, result} = LangEx.invoke(graph, %{messages: [Message.human("plan it")]})

      assert [%{"content" => "investigate", "status" => "in_progress"}] = result.todos
      assert %Message.AI{content: "done"} = List.last(result.messages)
    end

    test "contributes the tool to the agent" do
      assert [%Tool{name: "write_todos"}] = TodoList.new().tools
    end
  end

  defp reply(true), do: {:ok, Message.ai("done"), %{input_tokens: 1, output_tokens: 1}}

  defp reply(false) do
    call = %Message.ToolCall{
      name: "write_todos",
      id: "t1",
      args: %{"todos" => [%{"content" => "investigate", "status" => "in_progress"}]}
    }

    {:ok, Message.ai(nil, tool_calls: [call]), %{input_tokens: 1, output_tokens: 1}}
  end
end
