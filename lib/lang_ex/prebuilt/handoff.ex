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
  - `:active_agent_key` - state key holding the active agent
    (default `:active_agent`)
  """
  @spec tool(atom(), keyword()) :: Tool.t()
  def tool(target, opts \\ []) when is_atom(target) do
    key = Keyword.get(opts, :active_agent_key, :active_agent)

    %Tool{
      name: tool_name(target, opts),
      description: Keyword.get(opts, :description, "Ask agent '#{target}' for help."),
      parameters: %{type: "object", properties: %{}, required: []},
      function: transfer_fn(target, key)
    }
  end

  defp tool_name(target, opts) do
    opts
    |> Keyword.get(:name)
    |> named_or_prefixed(target, Keyword.get(opts, :prefix))
  end

  defp named_or_prefixed(nil, target, nil), do: "transfer_to_#{target}"
  defp named_or_prefixed(nil, target, prefix), do: "#{prefix}#{target}"
  defp named_or_prefixed(name, _target, _prefix), do: name

  defp transfer_fn(target, key) do
    fn _args, %{tool_call_id: id} ->
      %Command{
        update: %{
          key => target,
          messages: [Message.tool("Successfully transferred to #{target}.", id)]
        }
      }
    end
  end
end
