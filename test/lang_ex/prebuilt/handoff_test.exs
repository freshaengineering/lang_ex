defmodule LangEx.Prebuilt.HandoffTest do
  use ExUnit.Case, async: true

  alias LangEx.Command
  alias LangEx.Message
  alias LangEx.Prebuilt.Handoff
  alias LangEx.Tool

  describe "tool/2" do
    test "defaults name and description to the target agent" do
      assert %Tool{name: "transfer_to_billing", description: "Ask agent 'billing' for help."} =
               Handoff.tool(:billing)
    end

    test "transferring sets the active agent and replies to the call" do
      %Tool{function: transfer} = Handoff.tool(:billing)

      assert %Command{
               update: %{
                 active_agent: :billing,
                 messages: [%Message.Tool{tool_call_id: "c1", content: content}]
               }
             } = transfer.(%{}, %{tool_call_id: "c1"})

      assert content =~ "billing"
    end

    test "name and description are overridable" do
      assert %Tool{name: "escalate", description: "Escalate now."} =
               Handoff.tool(:billing, name: "escalate", description: "Escalate now.")
    end

    test "a custom active_agent_key is honored" do
      %Tool{function: transfer} = Handoff.tool(:billing, active_agent_key: :current)

      assert %Command{update: %{current: :billing}} = transfer.(%{}, %{tool_call_id: "c1"})
    end

    test "a prefix builds the tool name from the target" do
      assert %Tool{name: "delegate_to_billing"} = Handoff.tool(:billing, prefix: "delegate_to_")
    end

    test "an explicit name overrides the prefix" do
      assert %Tool{name: "escalate"} = Handoff.tool(:billing, name: "escalate", prefix: "x_")
    end

    test "task_description adds a parameter and briefs the target agent" do
      %Tool{parameters: parameters, function: transfer} =
        Handoff.tool(:billing, task_description: true)

      assert %{properties: %{task_description: %{type: "string"}}} = parameters

      assert %Command{
               update: %{
                 active_agent: :billing,
                 messages: [
                   %Message.Tool{},
                   %Message.Human{content: "Task for billing: issue a refund"}
                 ]
               }
             } = transfer.(%{"task_description" => "issue a refund"}, %{tool_call_id: "c1"})
    end

    test "a task-capable tool without a task given is a plain routing handoff" do
      %Tool{function: transfer} = Handoff.tool(:billing, task_description: true)

      assert %Command{update: %{active_agent: :billing, messages: [%Message.Tool{}]}} =
               transfer.(%{}, %{tool_call_id: "c1"})
    end
  end
end
