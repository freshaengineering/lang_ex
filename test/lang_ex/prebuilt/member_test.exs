defmodule LangEx.Prebuilt.MemberTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Graph
  alias LangEx.Interrupt
  alias LangEx.Message
  alias LangEx.Prebuilt.Handoff
  alias LangEx.Prebuilt.Member
  alias LangEx.Store
  alias LangEx.Tool

  describe "active_agent_key/0" do
    test "names the state key teams route on" do
      assert Member.active_agent_key() == :active_agent
    end
  end

  describe "tool_router/1" do
    test "keeps looping while the member is (or nobody is) active" do
      route = Member.tool_router(:alice)

      assert route.(%{active_agent: :alice}) == :agent
      assert route.(%{active_agent: nil}) == :agent
    end

    test "ends the turn once another agent is active" do
      assert Member.tool_router(:alice).(%{active_agent: :bob}) == :__end__
    end
  end

  describe "build/1 and node/3" do
    test "a member without tools runs a single turn" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("just chat"), usage()}
      end)

      member = Member.build(provider: LangEx.LLM.OpenAI, model: "gpt-4o", name: :solo)

      result = Member.node(member, :solo, :full_history).(%{messages: [Message.human("hi")]}, nil)

      assert %{active_agent: :solo, messages: [%Message.AI{content: "just chat"}]} = result
    end

    test "a member contributes only the messages it produced this turn" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("answer"), usage()}
      end)

      member = Member.build(provider: LangEx.LLM.OpenAI, model: "gpt-4o", name: :solo)
      prior = [Message.human("earlier"), Message.ai("earlier reply")]

      result = Member.node(member, :solo, :full_history).(%{messages: prior}, nil)

      assert %{messages: [%Message.AI{content: "answer"}]} = result
    end

    test "a handoff tool ends the turn and sets the next active agent" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &transfer_then_answer/2)

      member =
        Member.build(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          name: :alice,
          handoff_tools: [Handoff.tool(:bob)]
        )

      result =
        Member.node(member, :alice, :full_history).(%{messages: [Message.human("hi")]}, nil)

      assert %{
               active_agent: :bob,
               messages: [%Message.AI{tool_calls: [_]}, %Message.Tool{}]
             } = result
    end

    test "prepends the system prompt when the conversation has none" do
      test_pid = self()

      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn messages, _opts ->
        send(test_pid, {:seen, messages})
        {:ok, Message.ai("ok"), usage()}
      end)

      member =
        Member.build(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          name: :solo,
          system_prompt: "Be brief."
        )

      Member.node(member, :solo, :full_history).(%{messages: [Message.human("hi")]}, nil)

      assert_received {:seen, [%Message.System{content: "Be brief."}, %Message.Human{}]}
    end

    test "keeps an existing system message instead of prepending another" do
      test_pid = self()

      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn messages, _opts ->
        send(test_pid, {:seen, messages})
        {:ok, Message.ai("ok"), usage()}
      end)

      member =
        Member.build(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          name: :solo,
          system_prompt: "Be brief."
        )

      conversation = [Message.system("Custom system."), Message.human("hi")]
      Member.node(member, :solo, :full_history).(%{messages: conversation}, nil)

      assert_received {:seen, [%Message.System{content: "Custom system."}, %Message.Human{}]}
    end

    test "compaction can be disabled" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("ok"), usage()}
      end)

      member =
        Member.build(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          name: :solo,
          system_prompt: "Be brief.",
          compaction: false
        )

      result = Member.node(member, :solo, :full_history).(%{messages: [Message.human("hi")]}, nil)

      assert %{messages: [%Message.AI{content: "ok"}]} = result
    end

    test "a callable system prompt is resolved from state" do
      test_pid = self()

      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn messages, _opts ->
        send(test_pid, {:seen, messages})
        {:ok, Message.ai("ok"), usage()}
      end)

      member =
        Member.build(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          name: :solo,
          system_prompt: fn state -> "seen #{length(state.messages)} message(s)" end
        )

      Member.node(member, :solo, :full_history).(%{messages: [Message.human("hi")]}, nil)

      assert_received {:seen, [%Message.System{content: "seen 1 message(s)"}, %Message.Human{}]}
    end

    test "member tools reach the attached store" do
      Store.ETS.clear()
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &save_then_answer/2)

      member =
        Member.build(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          name: :solo,
          tools: [save_tool()],
          store: Store.ETS
        )

      Member.node(member, :solo, :full_history).(%{messages: [Message.human("save it")]}, nil)

      assert {:ok, "hello"} = Store.ETS.get([], ["notes"], "latest")
    end

    test "the turn's token usage is contributed back" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("ok"), %{input_tokens: 7, output_tokens: 3}}
      end)

      member = Member.build(provider: LangEx.LLM.OpenAI, model: "gpt-4o", name: :solo)

      result = Member.node(member, :solo, :full_history).(%{messages: [Message.human("hi")]}, nil)

      assert %{llm_usage: %{input_tokens: 7, output_tokens: 3}} = result
    end

    test "pre_model_hook transforms the messages before the LLM call" do
      test_pid = self()

      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn messages, _opts ->
        send(test_pid, {:seen, messages})
        {:ok, Message.ai("ok"), usage()}
      end)

      member =
        Member.build(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          name: :solo,
          pre_model_hook: fn messages -> messages ++ [Message.system("HOOKED")] end
        )

      Member.node(member, :solo, :full_history).(%{messages: [Message.human("hi")]}, nil)

      assert_received {:seen, seen}
      assert Enum.any?(seen, &match?(%Message.System{content: "HOOKED"}, &1))
    end

    test "post_model_hook transforms the produced messages" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("raw"), usage()}
      end)

      member =
        Member.build(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          name: :solo,
          post_model_hook: fn update ->
            Map.update!(update, :messages, fn msgs ->
              Enum.map(msgs, fn m -> %{m | content: m.content <> " [checked]"} end)
            end)
          end
        )

      result = Member.node(member, :solo, :full_history).(%{messages: [Message.human("hi")]}, nil)

      assert %{messages: [%Message.AI{content: "raw [checked]"}]} = result
    end

    test "last_message mode contributes only the final message" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &tool_then_answer/2)

      member =
        Member.build(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          name: :solo,
          tools: [ping_tool()]
        )

      result = Member.node(member, :solo, :last_message).(%{messages: [Message.human("hi")]}, nil)

      assert %{messages: [%Message.AI{content: "done"}]} = result
    end
  end

  describe "node/3 propagation" do
    test "an interrupt inside a member propagates so the team can pause" do
      member =
        Graph.new(messages: {[], &Message.add_messages/2}, active_agent: :x)
        |> Graph.add_node(:pause, fn _state -> %{approved: Interrupt.interrupt("ok?")} end)
        |> Graph.add_edge(:__start__, :pause)
        |> Graph.add_edge(:pause, :__end__)
        |> Graph.compile()

      node = Member.node(member, :x, :full_history)

      assert catch_throw(node.(%{messages: []}, nil)) == {:lang_ex_interrupt, "pause:0", "ok?"}
    end

    test "an error inside a member propagates as a graph error" do
      member =
        Graph.new(messages: {[], &Message.add_messages/2}, active_agent: :x)
        |> Graph.add_node(:boom, fn _state -> raise "kaboom" end)
        |> Graph.add_edge(:__start__, :boom)
        |> Graph.add_edge(:boom, :__end__)
        |> Graph.compile()

      node = Member.node(member, :x, :full_history)

      assert {:lang_ex_graph_error, %LangEx.NodeError{reason: %RuntimeError{message: "kaboom"}}} =
               catch_throw(node.(%{messages: []}, nil))
    end
  end

  defp ping_tool do
    %Tool{
      name: "ping",
      description: "Pings",
      parameters: %{},
      function: fn _args -> %{pong: true} end
    }
  end

  defp save_tool do
    %Tool{
      name: "save_note",
      description: "Persist a note",
      parameters: %{},
      function: fn %{"note" => note}, %{store: {module, config}} ->
        :ok = module.put(config, ["notes"], "latest", note)
        "saved"
      end
    }
  end

  defp save_then_answer(messages, _opts) do
    messages
    |> Enum.any?(&match?(%Message.Tool{}, &1))
    |> save_step()
  end

  defp save_step(false) do
    call = %Message.ToolCall{name: "save_note", id: "s1", args: %{"note" => "hello"}}
    {:ok, Message.ai(nil, tool_calls: [call]), usage()}
  end

  defp save_step(true), do: {:ok, Message.ai("saved"), usage()}

  defp transfer_then_answer(messages, _opts) do
    messages
    |> Enum.any?(&match?(%Message.Tool{}, &1))
    |> transfer_reply()
  end

  defp transfer_reply(false) do
    call = %Message.ToolCall{name: "transfer_to_bob", id: "t1", args: %{}}
    {:ok, Message.ai(nil, tool_calls: [call]), usage()}
  end

  defp transfer_reply(true), do: {:ok, Message.ai("after handoff"), usage()}

  defp tool_then_answer(messages, _opts) do
    messages
    |> Enum.any?(&match?(%Message.Tool{}, &1))
    |> tool_reply()
  end

  defp tool_reply(false) do
    call = %Message.ToolCall{name: "ping", id: "p1", args: %{}}
    {:ok, Message.ai(nil, tool_calls: [call]), usage()}
  end

  defp tool_reply(true), do: {:ok, Message.ai("done"), usage()}

  defp usage, do: %{input_tokens: 1, output_tokens: 1}
end
