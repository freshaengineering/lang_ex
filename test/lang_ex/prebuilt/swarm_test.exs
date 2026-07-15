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

    test "add_agent_name prefixes each agent's replies" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("handled"), usage()}
      end)

      graph =
        Swarm.create(
          agents: [
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :alice,
              system_prompt: "You are alice."
            ]
          ],
          default_active_agent: :alice,
          add_agent_name: true
        )

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("hi")]})

      assert %Message.AI{content: "[alice] handled"} = List.last(state.messages)
    end

    test "add_agent_name leaves tool and empty messages untouched" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &lookup_then_answer/2)

      graph =
        Swarm.create(
          agents: [
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :alice,
              system_prompt: "You are alice.",
              tools: [lookup_tool()]
            ]
          ],
          default_active_agent: :alice,
          add_agent_name: true
        )

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("look it up")]})

      assert %Message.AI{content: "[alice] found it"} = List.last(state.messages)

      assert Enum.any?(state.messages, fn
               %Message.Tool{content: c} -> c =~ "data" and not String.starts_with?(c, "[alice]")
               _ -> false
             end)
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

    test "a member's inner node events and token deltas stream through the team" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, opts ->
        emit = Keyword.get(opts, :on_token)
        is_function(emit, 1) && emit.("handled ")
        is_function(emit, 1) && emit.("by alice")
        {:ok, Message.ai("handled by alice"), usage()}
      end)

      graph =
        Swarm.create(
          agents: [
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :alice,
              system_prompt: "You are alice."
            ]
          ],
          default_active_agent: :alice
        )

      events =
        graph
        |> LangEx.stream(%{messages: [Message.human("hi")]}, modes: [:updates, :messages])
        |> Enum.to_list()

      assert Enum.any?(events, &match?({:node_start, :agent}, &1))
      assert Enum.any?(events, &match?({:message_delta, %{node: :agent, text: "handled "}}, &1))
    end

    test "an interrupt inside a member pauses the team and resumes at the team level" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("all set"), usage()}
      end)

      approve = fn messages ->
        LangEx.Interrupt.interrupt("approve?")
        messages
      end

      graph =
        Swarm.create(
          checkpointer: LangEx.Checkpointer.Memory,
          default_active_agent: :agent1,
          agents: [
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :agent1,
              system_prompt: "You are agent1.",
              pre_model_hook: approve
            ]
          ]
        )

      config = [thread_id: "swarm-hitl-1"]

      assert {:interrupt, "approve?", _paused} =
               LangEx.invoke(graph, %{messages: [Message.human("hi")]}, config: config)

      assert {:ok, state} =
               LangEx.invoke(graph, %LangEx.Command{resume: :approved}, config: config)

      assert %Message.AI{content: "all set"} = List.last(state.messages)
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

    test "interrupt_before pauses before an agent runs and resumes" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &scripted/2)

      graph = swarm(checkpointer: LangEx.Checkpointer.Memory, interrupt_before: [:bob])
      config = [thread_id: "swarm-bp-1"]

      assert {:interrupt, {:interrupt_before, :bob}, _paused} =
               LangEx.invoke(graph, %{messages: [Message.human("help")]}, config: config)

      assert {:ok, state} = LangEx.invoke(graph, %LangEx.Command{resume: true}, config: config)
      assert %{active_agent: :bob} = state
      assert %Message.AI{content: "done by bob"} = List.last(state.messages)
    end
  end

  describe "create/1 custom state" do
    test "rejects a state_schema that redefines a reserved key" do
      assert_raise ArgumentError, ~r/reserved team key/, fn ->
        Swarm.create(
          agents: [[name: :a, model: "gpt-4o"]],
          default_active_agent: :a,
          state_schema: [messages: []]
        )
      end
    end

    test "a reducer-backed custom key accumulates exactly once across a handoff" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &log_script/2)

      graph =
        Swarm.create(
          state_schema: [log: {[], fn current, new -> current ++ new end}],
          default_active_agent: :alice,
          agents: [
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :alice,
              system_prompt: "You are alice.",
              tools: [log_tool("a")]
            ],
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :bob,
              system_prompt: "You are bob.",
              tools: [log_tool("b")]
            ]
          ]
        )

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("go")]})

      assert state.log == ["a", "b"]
    end

    test "a last-write-wins custom key is readable and writable across members" do
      test_pid = self()
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &owner_script/2)

      graph =
        Swarm.create(
          state_schema: [owner: nil],
          default_active_agent: :alice,
          agents: [
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :alice,
              system_prompt: "You are alice.",
              tools: [set_owner_tool()]
            ],
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :bob,
              system_prompt: "You are bob.",
              tools: [read_owner_tool(test_pid)]
            ]
          ]
        )

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("go")]})

      assert %{owner: :vip} = state
      assert_received {:owner_seen, :vip}
    end
  end

  defp log_script(messages, _opts), do: log_respond(role(messages), messages)

  defp log_respond(:alice, _messages) do
    calls = [
      %Message.ToolCall{name: "log_a", id: "la", args: %{}},
      %Message.ToolCall{name: "transfer_to_bob", id: "tb", args: %{}}
    ]

    {:ok, Message.ai(nil, tool_calls: calls), usage()}
  end

  defp log_respond(:bob, messages) do
    messages
    |> Enum.any?(&match?(%Message.Tool{tool_call_id: "lb"}, &1))
    |> bob_log_step()
  end

  defp bob_log_step(true), do: {:ok, Message.ai("logged"), usage()}

  defp bob_log_step(false) do
    {:ok, Message.ai(nil, tool_calls: [%Message.ToolCall{name: "log_b", id: "lb", args: %{}}]),
     usage()}
  end

  defp log_tool(entry) do
    %LangEx.Tool{
      name: "log_#{entry}",
      description: "Records #{entry}.",
      parameters: %{type: "object", properties: %{}, required: []},
      function: fn _args -> %LangEx.Command{update: %{log: [entry]}} end
    }
  end

  defp owner_script(messages, _opts), do: owner_respond(role(messages), messages)

  defp owner_respond(:alice, _messages) do
    calls = [
      %Message.ToolCall{name: "set_owner", id: "so", args: %{}},
      %Message.ToolCall{name: "transfer_to_bob", id: "tb", args: %{}}
    ]

    {:ok, Message.ai(nil, tool_calls: calls), usage()}
  end

  defp owner_respond(:bob, messages) do
    messages
    |> Enum.any?(&match?(%Message.Tool{tool_call_id: "ro"}, &1))
    |> bob_read_step()
  end

  defp bob_read_step(true), do: {:ok, Message.ai("read"), usage()}

  defp bob_read_step(false) do
    {:ok,
     Message.ai(nil, tool_calls: [%Message.ToolCall{name: "read_owner", id: "ro", args: %{}}]),
     usage()}
  end

  defp set_owner_tool do
    %LangEx.Tool{
      name: "set_owner",
      description: "Sets the owner.",
      parameters: %{type: "object", properties: %{}, required: []},
      function: fn _args -> %LangEx.Command{update: %{owner: :vip}} end
    }
  end

  defp read_owner_tool(test_pid) do
    %LangEx.Tool{
      name: "read_owner",
      description: "Reads the owner.",
      parameters: %{type: "object", properties: %{}, required: []},
      function: fn _args, %{state: state} ->
        send(test_pid, {:owner_seen, Map.get(state, :owner)})
        %{acknowledged: true}
      end
    }
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

  defp lookup_then_answer(messages, _opts) do
    messages
    |> Enum.any?(&match?(%Message.Tool{}, &1))
    |> answer_step()
  end

  defp answer_step(false) do
    call = %Message.ToolCall{name: "lookup", id: "l1", args: %{}}
    {:ok, Message.ai(nil, tool_calls: [call]), usage()}
  end

  defp answer_step(true), do: {:ok, Message.ai("found it"), usage()}

  defp usage, do: %{input_tokens: 1, output_tokens: 1}
end
