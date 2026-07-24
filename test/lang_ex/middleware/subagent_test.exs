defmodule LangEx.Middleware.SubagentTest do
  use ExUnit.Case, async: true
  use Mimic

  alias LangEx.Command
  alias LangEx.Message
  alias LangEx.Middleware.Subagent
  alias LangEx.Tool

  describe "new/1" do
    test "exposes a task tool describing each configured subagent" do
      middleware =
        Subagent.new(
          subagents: [
            %{
              name: "log-miner",
              description: "Deep-dives logs to find root causes.",
              system_prompt: "You are a log analysis expert."
            },
            %{
              name: "doc-writer",
              description: "Drafts incident documentation.",
              system_prompt: "You are a technical writer."
            }
          ],
          provider: LangEx.LLM.Anthropic,
          model: "claude-sonnet-5"
        )

      assert [%Tool{name: "task", description: description, parameters: parameters}] =
               middleware.tools

      assert description =~ "log-miner"
      assert description =~ "Deep-dives logs to find root causes."
      assert description =~ "doc-writer"
      assert description =~ "Drafts incident documentation."

      assert %{"properties" => %{"subagent_type" => %{"enum" => ["log-miner", "doc-writer"]}}} =
               parameters
    end
  end

  describe "task tool" do
    test "runs the child agent and returns its report with usage" do
      stub(LangEx.LLM.Anthropic, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("child report"), %{input_tokens: 3, output_tokens: 5}}
      end)

      middleware =
        Subagent.new(
          subagents: [
            %{
              name: "log-miner",
              description: "Deep-dives logs to find root causes.",
              system_prompt: "You are a log analysis expert."
            }
          ],
          provider: LangEx.LLM.Anthropic,
          model: "claude-sonnet-5"
        )

      assert [%Tool{name: "task", function: function}] = middleware.tools

      result =
        function.(
          %{"description" => "Find the root cause of the 500s", "subagent_type" => "log-miner"},
          %{state: %{}, store: nil, tool_call_id: "call_1"}
        )

      assert %Command{update: %{messages: [message], llm_usage: usage}} = result
      assert %Message.Tool{content: "child report", tool_call_id: "call_1"} = message
      assert %{input_tokens: 3, output_tokens: 5} = usage
    end

    test "unknown subagent_type returns an error string" do
      middleware =
        Subagent.new(
          subagents: [
            %{
              name: "log-miner",
              description: "Deep-dives logs to find root causes.",
              system_prompt: "You are a log analysis expert."
            }
          ],
          provider: LangEx.LLM.Anthropic,
          model: "claude-sonnet-5"
        )

      assert [%Tool{name: "task", function: function}] = middleware.tools

      result =
        function.(
          %{"description" => "Do something", "subagent_type" => "ghost"},
          %{state: %{}, store: nil, tool_call_id: "call_2"}
        )

      assert result == "Unknown subagent_type: ghost. Available: log-miner"
    end

    test "child failure yields a failed string instead of raising" do
      stub(LangEx.LLM.Anthropic, :chat_with_usage, fn _messages, _opts ->
        {:error, :boom}
      end)

      middleware =
        Subagent.new(
          subagents: [
            %{
              name: "log-miner",
              description: "Deep-dives logs to find root causes.",
              system_prompt: "You are a log analysis expert."
            }
          ],
          provider: LangEx.LLM.Anthropic,
          model: "claude-sonnet-5"
        )

      assert [%Tool{name: "task", function: function}] = middleware.tools

      result =
        function.(
          %{"description" => "Find the root cause", "subagent_type" => "log-miner"},
          %{state: %{}, store: nil, tool_call_id: "call_3"}
        )

      assert result =~ "Subagent log-miner failed: "
    end

    test "inherit_keys seeds the child's state so state-derived tools materialize" do
      test_pid = self()

      stub(LangEx.LLM.Anthropic, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("done"), %{input_tokens: 1, output_tokens: 1}}
      end)

      middleware =
        Subagent.new(
          subagents: [
            %{
              name: "prober",
              description: "Probes with inherited tools.",
              system_prompt: "You probe.",
              inherit_keys: [:tool_specs, :session],
              tools: fn child_state ->
                send(test_pid, {:child_state_keys, child_state |> Map.keys() |> Enum.sort()})
                []
              end
            }
          ],
          provider: LangEx.LLM.Anthropic,
          model: "claude-sonnet-5"
        )

      [%Tool{function: function}] = middleware.tools

      %Command{} =
        function.(
          %{"description" => "probe", "subagent_type" => "prober"},
          %{
            state: %{tool_specs: [:spec], session: %{token: "t"}, secret: "hidden"},
            store: nil,
            tool_call_id: "call_9"
          }
        )

      assert_received {:child_state_keys, keys}
      assert :tool_specs in keys
      assert :session in keys
      refute :secret in keys
    end
  end
end
