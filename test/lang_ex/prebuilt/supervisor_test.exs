defmodule LangEx.Prebuilt.SupervisorTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Message
  alias LangEx.Prebuilt.Supervisor

  describe "create/1" do
    test "delegates to a worker, then finalizes when control returns" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &scripted/2)

      graph = supervisor()

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("do the thing")]})

      assert %{active_agent: :supervisor} = state
      assert %Message.AI{content: "all done"} = List.last(state.messages)
      assert Enum.any?(state.messages, &match?(%Message.AI{content: "worker done"}, &1))
    end

    test "the supervisor can answer directly without delegating" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("answered directly"), usage()}
      end)

      {:ok, state} = LangEx.invoke(supervisor(), %{messages: [Message.human("hi")]})

      assert %{active_agent: :supervisor} = state
      assert %Message.AI{content: "answered directly"} = List.last(state.messages)
    end

    test "delegates to several workers in turn and routes each to the right one" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &two_worker_script/2)

      graph =
        Supervisor.create(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          prompt: "You are supervisor.",
          agents: [
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :research,
              system_prompt: "You are research."
            ],
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :math,
              system_prompt: "You are math."
            ]
          ]
        )

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("do both")]})

      assert %{active_agent: :supervisor} = state
      assert %Message.AI{content: "all complete"} = List.last(state.messages)
      assert Enum.any?(state.messages, &match?(%Message.AI{content: "research done"}, &1))
      assert Enum.any?(state.messages, &match?(%Message.AI{content: "math done"}, &1))
    end

    test "a custom supervisor name is used for routing" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("done by boss"), usage()}
      end)

      graph =
        Supervisor.create(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          supervisor_name: :boss,
          agents: [[provider: LangEx.LLM.OpenAI, model: "gpt-4o", name: :worker]]
        )

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("hi")]})

      assert %{active_agent: :boss} = state
      assert %Message.AI{content: "done by boss"} = List.last(state.messages)
    end

    test "add_handoff_back_messages records each return to the supervisor" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &scripted/2)

      graph = supervisor(add_handoff_back_messages: true)

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("do the thing")]})

      assert Enum.any?(state.messages, fn
               %Message.Human{content: content} -> content =~ "Control returned to supervisor"
               _ -> false
             end)
    end

    test "last_message output mode contributes only the worker's final message" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &scripted/2)

      graph = supervisor(output_mode: :last_message)

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("do the thing")]})

      worker_messages =
        Enum.filter(state.messages, &match?(%Message.AI{content: "worker done"}, &1))

      assert length(worker_messages) == 1
    end
  end

  defp supervisor(opts \\ []) do
    Supervisor.create(
      [
        provider: LangEx.LLM.OpenAI,
        model: "gpt-4o",
        prompt: "You are supervisor.",
        agents: [
          [
            provider: LangEx.LLM.OpenAI,
            model: "gpt-4o",
            name: :worker,
            system_prompt: "You are worker."
          ]
        ]
      ] ++ opts
    )
  end

  defp scripted(messages, _opts) do
    messages
    |> role()
    |> respond(messages)
  end

  defp role(messages) do
    Enum.find_value(messages, fn
      %Message.System{content: "You are worker."} -> :worker
      %Message.System{content: "You are supervisor."} -> :supervisor
      _ -> nil
    end)
  end

  defp respond(:worker, _messages), do: {:ok, Message.ai("worker done"), usage()}

  defp respond(:supervisor, messages) do
    messages
    |> Enum.any?(&match?(%Message.AI{content: "worker done"}, &1))
    |> supervisor_turn()
  end

  defp supervisor_turn(true), do: {:ok, Message.ai("all done"), usage()}

  defp supervisor_turn(false) do
    call = %Message.ToolCall{name: "transfer_to_worker", id: "t1", args: %{}}
    {:ok, Message.ai(nil, tool_calls: [call]), usage()}
  end

  defp two_worker_script(messages, _opts) do
    messages
    |> two_worker_role()
    |> two_worker_respond(messages)
  end

  defp two_worker_role(messages) do
    Enum.find_value(messages, fn
      %Message.System{content: "You are research."} -> :research
      %Message.System{content: "You are math."} -> :math
      %Message.System{content: "You are supervisor."} -> :supervisor
      _ -> nil
    end)
  end

  defp two_worker_respond(:research, _messages), do: {:ok, Message.ai("research done"), usage()}
  defp two_worker_respond(:math, _messages), do: {:ok, Message.ai("math done"), usage()}

  defp two_worker_respond(:supervisor, messages) do
    {seen?(messages, "research done"), seen?(messages, "math done")}
    |> supervisor_step()
  end

  defp supervisor_step({false, _math}), do: transfer_call(:research)
  defp supervisor_step({true, false}), do: transfer_call(:math)
  defp supervisor_step({true, true}), do: {:ok, Message.ai("all complete"), usage()}

  defp seen?(messages, content),
    do: Enum.any?(messages, &match?(%Message.AI{content: ^content}, &1))

  defp transfer_call(worker) do
    call = %Message.ToolCall{name: "transfer_to_#{worker}", id: "t-#{worker}", args: %{}}
    {:ok, Message.ai(nil, tool_calls: [call]), usage()}
  end

  defp usage, do: %{input_tokens: 1, output_tokens: 1}
end
