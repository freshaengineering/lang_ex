defmodule LangEx.Middleware.TodoList do
  @moduledoc """
  Middleware that gives the agent an explicit planning tool.

  Contributes a `write_todos` tool plus a `:todos` state key. The agent
  records and revises a task list as it works, which keeps a long multi-step
  loop anchored to a plan instead of drifting — one of the cheapest quality
  gains for multi-step agents. The current plan lives in graph state (and
  therefore in checkpoints), so it survives pauses and resumes.

  Encourage use from the agent's system prompt (e.g. "Before acting, write a
  todo list and keep it updated.").

  ## Options

  - `:description` - override the tool description shown to the model
  """

  alias LangEx.Command
  alias LangEx.Message
  alias LangEx.Middleware
  alias LangEx.Tool

  @default_description "Record or update your task plan. Always pass the FULL list; " <>
                         "it replaces the previous plan. Mark items in_progress or " <>
                         "completed as you go."

  @todo_schema %{
    "type" => "object",
    "properties" => %{
      "todos" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "content" => %{"type" => "string", "description" => "the task"},
            "status" => %{
              "type" => "string",
              "enum" => ["pending", "in_progress", "completed"]
            }
          },
          "required" => ["content", "status"]
        }
      }
    },
    "required" => ["todos"]
  }

  @doc "Builds a todo-list planning middleware. See the module doc for options."
  @spec new(keyword()) :: Middleware.t()
  def new(opts \\ []) do
    Middleware.new(
      name: :todo_list,
      tools: [todo_tool(Keyword.get(opts, :description, @default_description))],
      state_schema: [todos: []]
    )
  end

  defp todo_tool(description) do
    %Tool{
      name: "write_todos",
      description: description,
      parameters: @todo_schema,
      function: &record/2
    }
  end

  defp record(%{"todos" => todos}, %{tool_call_id: id}) do
    %Command{
      update: %{
        todos: todos,
        messages: [Message.tool("Recorded #{length(todos)} todo(s).", id)]
      }
    }
  end
end
