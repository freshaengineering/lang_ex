defmodule LangEx.Prebuilt.SwarmTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Message
  alias LangEx.Prebuilt.Swarm

  describe "create/1 validation" do
    test "rejects an empty agent list" do
      assert_raise ArgumentError, ~r/at least one agent/, fn ->
        Swarm.create(agents: [], default_active_agent: :a)
      end
    end

    test "rejects duplicate agent names" do
      assert_raise ArgumentError, ~r/duplicate agent name/, fn ->
        Swarm.create(
          agents: [[name: :a, model: "gpt-4o"], [name: :a, model: "gpt-4o"]],
          default_active_agent: :a
        )
      end
    end

    test "rejects a default that is not one of the agents" do
      assert_raise ArgumentError, ~r/default_active_agent :ghost must be one of/, fn ->
        Swarm.create(agents: [[name: :a, model: "gpt-4o"]], default_active_agent: :ghost)
      end
    end
  end

  describe "create/1" do
    test "the default agent handles the turn until it hands off to a peer" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &scripted/2)

      graph = swarm()

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("help")]})

      assert %{active_agent: :bob} = state

      assert [
               %Message.Human{},
               %Message.AI{tool_calls: [%Message.ToolCall{name: "transfer_to_bob"}]},
               %Message.Tool{},
               %Message.AI{content: "done by bob"}
             ] = state.messages
    end

    test "an agent that does not hand off ends the turn itself" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("handled by alice"), usage()}
      end)

      {:ok, state} = LangEx.invoke(swarm(), %{messages: [Message.human("hi")]})

      assert %{active_agent: :alice} = state
      assert %Message.AI{content: "handled by alice"} = List.last(state.messages)
    end

    test "an agent uses its own tools before handing off" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &lookup_then_handoff/2)

      graph =
        Swarm.create(
          agents: [
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :alice,
              system_prompt: "You are alice.",
              tools: [lookup_tool()]
            ],
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :bob,
              system_prompt: "You are bob."
            ]
          ],
          default_active_agent: :alice
        )

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("look it up")]})

      assert %{active_agent: :bob} = state
      assert %Message.AI{content: "done by bob"} = List.last(state.messages)

      assert Enum.any?(state.messages, fn
               %Message.Tool{content: content} -> content =~ "data"
               _ -> false
             end)
    end

    test "token usage accumulates across the team" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &scripted/2)

      {:ok, state} = LangEx.invoke(swarm(), %{messages: [Message.human("help")]})

      assert %{input_tokens: 2, output_tokens: 2} = state.llm_usage
    end

    test "a handoff_tool_prefix renames the generated handoff tools" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &prefixed_handoff/2)

      graph =
        Swarm.create(
          agents: [
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :alice,
              system_prompt: "You are alice."
            ],
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :bob,
              system_prompt: "You are bob."
            ]
          ],
          default_active_agent: :alice,
          handoff_tool_prefix: "delegate_to_"
        )

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("help")]})

      assert %{active_agent: :bob} = state
      assert %Message.AI{content: "done by bob"} = List.last(state.messages)
    end

    test "a team run can be streamed" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &scripted/2)

      events =
        swarm()
        |> LangEx.stream(%{messages: [Message.human("help")]})
        |> Enum.to_list()

      assert Enum.any?(events, &match?({:node_start, :alice}, &1))
      assert Enum.any?(events, &match?({:node_start, :bob}, &1))
      assert {:done, {:ok, %{active_agent: :bob}}} = List.last(events)
    end

    test "the active agent persists across invocations" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &scripted/2)

      graph = swarm(checkpointer: LangEx.Checkpointer.Memory)
      config = [thread_id: "swarm-persist-1"]

      {:ok, _first} = LangEx.invoke(graph, %{messages: [Message.human("help")]}, config: config)
      {:ok, second} = LangEx.invoke(graph, %{messages: [Message.human("again")]}, config: config)

      assert %{active_agent: :bob} = second
      assert %Message.AI{content: "done by bob"} = List.last(second.messages)
    end
  end

  defp swarm(opts \\ []) do
    Swarm.create(
      [
        agents: [
          [
            provider: LangEx.LLM.OpenAI,
            model: "gpt-4o",
            name: :alice,
            system_prompt: "You are alice."
          ],
          [
            provider: LangEx.LLM.OpenAI,
            model: "gpt-4o",
            name: :bob,
            system_prompt: "You are bob."
          ]
        ],
        default_active_agent: :alice
      ] ++ opts
    )
  end

  defp scripted(messages, _opts) do
    messages
    |> role()
    |> respond()
  end

  defp role(messages) do
    Enum.find_value(messages, fn
      %Message.System{content: "You are bob."} -> :bob
      %Message.System{content: "You are alice."} -> :alice
      _ -> nil
    end)
  end

  defp respond(:bob), do: {:ok, Message.ai("done by bob"), usage()}

  defp respond(:alice) do
    call = %Message.ToolCall{name: "transfer_to_bob", id: "t1", args: %{}}
    {:ok, Message.ai(nil, tool_calls: [call]), usage()}
  end

  defp prefixed_handoff(messages, _opts) do
    messages
    |> role()
    |> prefixed_respond()
  end

  defp prefixed_respond(:bob), do: {:ok, Message.ai("done by bob"), usage()}

  defp prefixed_respond(:alice) do
    call = %Message.ToolCall{name: "delegate_to_bob", id: "t1", args: %{}}
    {:ok, Message.ai(nil, tool_calls: [call]), usage()}
  end

  defp lookup_then_handoff(messages, _opts) do
    messages
    |> role()
    |> lookup_respond(messages)
  end

  defp lookup_respond(:bob, _messages), do: {:ok, Message.ai("done by bob"), usage()}

  defp lookup_respond(:alice, messages) do
    messages
    |> Enum.any?(&match?(%Message.Tool{}, &1))
    |> alice_step()
  end

  defp alice_step(false) do
    call = %Message.ToolCall{name: "lookup", id: "l1", args: %{}}
    {:ok, Message.ai(nil, tool_calls: [call]), usage()}
  end

  defp alice_step(true) do
    call = %Message.ToolCall{name: "transfer_to_bob", id: "t1", args: %{}}
    {:ok, Message.ai(nil, tool_calls: [call]), usage()}
  end

  defp lookup_tool do
    %LangEx.Tool{
      name: "lookup",
      description: "Looks up data",
      parameters: %{},
      function: fn _args -> %{result: "data"} end
    }
  end

  defp usage, do: %{input_tokens: 1, output_tokens: 1}
end
