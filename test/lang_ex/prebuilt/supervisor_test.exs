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
      assert mentions?(state.messages, "Response from the worker agent")
      assert mentions?(state.messages, "worker done")
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
      assert mentions?(state.messages, "research done")
      assert mentions?(state.messages, "math done")
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

    test "a worker's output is reported back attributed to that worker" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &scripted/2)

      {:ok, state} = LangEx.invoke(supervisor(), %{messages: [Message.human("do the thing")]})

      reports =
        Enum.filter(state.messages, fn
          %Message.Human{content: c} -> c =~ "Response from the worker agent"
          _ -> false
        end)

      assert [%Message.Human{content: content}] = reports
      assert content =~ "worker done"
    end

    test "last_message output mode reports only the worker's final message" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &scripted/2)

      graph = supervisor(output_mode: :last_message)

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("do the thing")]})

      assert mentions?(state.messages, "worker done")
    end

    test "workers run on a task view that drops handoff plumbing but keeps context" do
      test_pid = self()

      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn messages, opts ->
        capture_worker_view(messages, test_pid)
        scripted(messages, opts)
      end)

      seed = [
        Message.ai("Earlier context: the customer is a VIP."),
        Message.human("do the thing")
      ]

      {:ok, _state} = LangEx.invoke(supervisor(), %{messages: seed})

      assert_received {:worker_view, view}

      assert Enum.any?(
               view,
               &match?(%Message.AI{content: "Earlier context: the customer is a VIP."}, &1)
             )

      assert Enum.any?(view, &match?(%Message.Human{content: "do the thing"}, &1))
      refute Enum.any?(view, fn m -> content(m) =~ "Successfully transferred" end)
    end

    @tag capture_log: true
    test "a worker that fails surfaces a clear error" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn messages, opts ->
        reply_for(role(messages), messages, opts)
      end)

      assert {:error, %LangEx.NodeError{reason: %RuntimeError{message: message}}} =
               LangEx.invoke(supervisor(), %{messages: [Message.human("do the thing")]})

      assert message =~ "worker :worker did not complete normally"
    end
  end

  defp reply_for(:worker, _messages, _opts), do: {:error, :simulated_failure}
  defp reply_for(_role, messages, opts), do: scripted(messages, opts)

  defp capture_worker_view(messages, test_pid) do
    forward_worker_view(role(messages), messages, test_pid)
  end

  defp forward_worker_view(:worker, messages, test_pid),
    do: send(test_pid, {:worker_view, messages})

  defp forward_worker_view(_role, _messages, _test_pid), do: :ok

  defp mentions?(messages, text) do
    Enum.any?(messages, fn message -> message |> content() |> String.contains?(text) end)
  end

  defp content(%{content: c}) when is_binary(c), do: c
  defp content(_message), do: ""

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
    |> mentions?("worker done")
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
    {mentions?(messages, "research done"), mentions?(messages, "math done")}
    |> supervisor_step()
  end

  defp supervisor_step({false, _math}), do: transfer_call(:research)
  defp supervisor_step({true, false}), do: transfer_call(:math)
  defp supervisor_step({true, true}), do: {:ok, Message.ai("all complete"), usage()}

  defp transfer_call(worker) do
    call = %Message.ToolCall{name: "transfer_to_#{worker}", id: "t-#{worker}", args: %{}}
    {:ok, Message.ai(nil, tool_calls: [call]), usage()}
  end

  defp usage, do: %{input_tokens: 1, output_tokens: 1}
end
