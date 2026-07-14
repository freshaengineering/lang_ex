defmodule LangEx.Prebuilt.Handoff do
  @moduledoc """
  Builds a tool that transfers control from the current agent to another.

  A handoff tool is an ordinary `%LangEx.Tool{}` whose function returns a
  `%LangEx.Command{}` setting `:active_agent` to the target and appending
  a short transfer reply. The prebuilt team topologies
  (`LangEx.Prebuilt.Swarm`, `LangEx.Prebuilt.Supervisor`) route on
  `:active_agent`, so calling the tool hands the conversation to the
  named agent on the next super-step.

      tools = [LangEx.Prebuilt.Handoff.tool(:billing)]

  The LLM sees a `transfer_to_billing` function; invoking it moves the
  active agent to `:billing`.
  """

  alias LangEx.Command
  alias LangEx.Message
  alias LangEx.Tool

  @doc """
  Returns a `%LangEx.Tool{}` that hands control to `target`.

  ## Options

  - `:name` - tool name the LLM calls (overrides `:prefix`; default
    `"transfer_to_<target>"`)
  - `:prefix` - prepended to the target name to form the tool name
    (e.g. `"delegate_to_"` yields `"delegate_to_<target>"`)
  - `:description` - tool description (default asks the target for help)
  - `:task_description` - when `true`, the tool accepts a
    `task_description` argument that is passed to the target agent as an
    explicit task brief (default `false`, a pure routing handoff)
  - `:active_agent_key` - state key holding the active agent
    (default `:active_agent`)
  """
  @spec tool(atom(), keyword()) :: Tool.t()
  def tool(target, opts \\ []) when is_atom(target) do
    %Tool{
      name: tool_name(target, opts),
      description: Keyword.get(opts, :description, "Ask agent '#{target}' for help."),
      parameters: parameters(Keyword.get(opts, :task_description, false), target),
      function: transfer_fn(target, Keyword.get(opts, :active_agent_key, :active_agent))
    }
  end

  defp parameters(false, _target), do: %{type: "object", properties: %{}, required: []}

  defp parameters(true, target) do
    %{
      type: "object",
      properties: %{
        task_description: %{
          type: "string",
          description: "Describe the task or question for the #{target} agent to handle."
        }
      },
      required: []
    }
  end

  defp tool_name(target, opts) do
    tool_name(Keyword.get(opts, :name), Keyword.get(opts, :prefix), target)
  end

  defp tool_name(nil, nil, target), do: "transfer_to_#{target}"
  defp tool_name(nil, prefix, target), do: "#{prefix}#{target}"
  defp tool_name(name, _prefix, _target), do: name

  defp transfer_fn(target, key) do
    fn args, %{tool_call_id: id} ->
      %Command{
        update: %{
          key => target,
          messages: transfer_messages(target, id, Map.get(args, "task_description"))
        }
      }
    end
  end

  defp transfer_messages(target, id, task) when is_binary(task) and task != "" do
    [
      Message.tool("Successfully transferred to #{target}.", id),
      Message.human("Task for #{target}: #{task}")
    ]
  end

  defp transfer_messages(target, id, _task) do
    [Message.tool("Successfully transferred to #{target}.", id)]
  end
end
