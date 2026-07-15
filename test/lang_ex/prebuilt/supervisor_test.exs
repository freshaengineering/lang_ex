defmodule LangEx.Prebuilt.SupervisorTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Message
  alias LangEx.Prebuilt.Supervisor

  describe "create/1 validation" do
    test "rejects an empty agent list" do
      assert_raise ArgumentError, ~r/at least one worker/, fn ->
        Supervisor.create(model: "gpt-4o", agents: [])
      end
    end

    test "rejects duplicate worker names" do
      assert_raise ArgumentError, ~r/duplicate agent name/, fn ->
        Supervisor.create(
          model: "gpt-4o",
          agents: [[name: :w, model: "gpt-4o"], [name: :w, model: "gpt-4o"]]
        )
      end
    end

    test "rejects a supervisor name that collides with a worker" do
      assert_raise ArgumentError, ~r/collides with a worker/, fn ->
        Supervisor.create(
          model: "gpt-4o",
          supervisor_name: :w,
          agents: [[name: :w, model: "gpt-4o"]]
        )
      end
    end

    test "rejects a state_schema that redefines a reserved key" do
      assert_raise ArgumentError, ~r/reserved team key/, fn ->
        Supervisor.create(
          model: "gpt-4o",
          state_schema: [messages: []],
          agents: [[name: :w, model: "gpt-4o"]]
        )
      end
    end
  end

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

    test "the supervisor's task brief reaches the worker" do
      test_pid = self()

      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn messages, opts ->
        capture_worker_view(messages, test_pid)
        task_scripted(messages, opts)
      end)

      {:ok, _state} = LangEx.invoke(supervisor(), %{messages: [Message.human("help")]})

      assert_received {:worker_view, view}
      assert Enum.any?(view, fn m -> content(m) =~ "Task for worker: investigate the outage" end)
    end

    test "interrupt_before pauses before a worker runs and resumes" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &scripted/2)

      graph = supervisor(checkpointer: LangEx.Checkpointer.Memory, interrupt_before: [:worker])
      config = [thread_id: "sup-bp-1"]

      assert {:interrupt, {:interrupt_before, :worker}, _paused} =
               LangEx.invoke(graph, %{messages: [Message.human("do the thing")]}, config: config)

      assert {:ok, state} = LangEx.invoke(graph, %LangEx.Command{resume: true}, config: config)
      assert %{active_agent: :supervisor} = state
      assert %Message.AI{content: "all done"} = List.last(state.messages)
    end

    test "an interrupt inside a worker pauses and resumes the team" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &scripted/2)

      approve = fn messages ->
        LangEx.Interrupt.interrupt("worker approve?")
        messages
      end

      graph =
        Supervisor.create(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          prompt: "You are supervisor.",
          checkpointer: LangEx.Checkpointer.Memory,
          agents: [
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :worker,
              system_prompt: "You are worker.",
              pre_model_hook: approve
            ]
          ]
        )

      config = [thread_id: "sup-hitl-1"]

      assert {:interrupt, "worker approve?", _paused} =
               LangEx.invoke(graph, %{messages: [Message.human("do the thing")]}, config: config)

      assert {:ok, state} =
               LangEx.invoke(graph, %LangEx.Command{resume: :ok}, config: config)

      assert %{active_agent: :supervisor} = state
      assert %Message.AI{content: "all done"} = List.last(state.messages)
    end

    @tag capture_log: true
    test "a worker that fails surfaces the worker's error" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn messages, opts ->
        reply_for(role(messages), messages, opts)
      end)

      assert {:error, %LangEx.NodeError{reason: %RuntimeError{}}} =
               LangEx.invoke(supervisor(), %{messages: [Message.human("do the thing")]})
    end
  end

  describe "create/1 parallel" do
    test "delegates to several workers concurrently and fans results back in one step" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &parallel_script/2)

      {:ok, state} =
        LangEx.invoke(parallel_supervisor(), %{messages: [Message.human("do both")]})

      assert %{active_agent: :supervisor} = state
      assert %Message.AI{content: "all complete"} = List.last(state.messages)
      assert mentions?(state.messages, "research done")
      assert mentions?(state.messages, "math done")
      assert %{input_tokens: 4, output_tokens: 4} = state.llm_usage
    end

    test "each concurrent worker sees only its own task brief" do
      test_pid = self()

      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn messages, opts ->
        capture_parallel_view(messages, test_pid)
        parallel_task_script(messages, opts)
      end)

      {:ok, _state} =
        LangEx.invoke(parallel_supervisor(), %{messages: [Message.human("investigate")]})

      assert_received {:worker_view, :research, research_view}
      assert_received {:worker_view, :math, math_view}

      assert Enum.any?(research_view, fn m -> content(m) =~ "check the logs" end)
      refute Enum.any?(research_view, fn m -> content(m) =~ "compute the totals" end)
      assert Enum.any?(math_view, fn m -> content(m) =~ "compute the totals" end)
      refute Enum.any?(math_view, fn m -> content(m) =~ "check the logs" end)
    end
  end

  describe "create/1 forward_message" do
    test "forwards a worker's reply verbatim as the final answer" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &forward_script/2)

      graph = supervisor(forward_message: true)

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("do the thing")]})

      assert %Message.AI{content: "the detailed worker answer"} = List.last(state.messages)
    end

    test "forwarding with no matching report yields an empty answer" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        call = %Message.ToolCall{name: "forward_message", id: "f1", args: %{"from" => "worker"}}
        {:ok, Message.ai(nil, tool_calls: [call]), usage()}
      end)

      graph = supervisor(forward_message: true)

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("do the thing")]})

      assert %Message.AI{content: ""} = List.last(state.messages)
    end
  end

  describe "create/1 parallel edge cases" do
    test "fan-out ignores non-worker tool calls made in the same turn" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &parallel_extra_tool_script/2)

      graph =
        Supervisor.create(
          parallel: true,
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          prompt: "You are supervisor.",
          tools: [ping_tool()],
          agents: [
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :research,
              system_prompt: "You are research."
            ]
          ]
        )

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("go")]})

      assert %Message.AI{content: "all complete"} = List.last(state.messages)
      assert mentions?(state.messages, "research done")
    end
  end

  defp parallel_extra_tool_script(messages, _opts) do
    parallel_extra_respond(two_worker_role(messages), messages)
  end

  defp parallel_extra_respond(:research, _messages),
    do: {:ok, Message.ai("research done"), usage()}

  defp parallel_extra_respond(:supervisor, messages) do
    messages
    |> mentions?("research done")
    |> parallel_extra_step()
  end

  defp parallel_extra_step(true), do: {:ok, Message.ai("all complete"), usage()}

  defp parallel_extra_step(false) do
    calls = [
      %Message.ToolCall{name: "transfer_to_research", id: "r1", args: %{}},
      %Message.ToolCall{name: "ping", id: "p1", args: %{}}
    ]

    {:ok, Message.ai(nil, tool_calls: calls), usage()}
  end

  defp ping_tool do
    %LangEx.Tool{
      name: "ping",
      description: "Pings.",
      parameters: %{type: "object", properties: %{}, required: []},
      function: fn _args -> %{pong: true} end
    }
  end

  defp forward_script(messages, _opts), do: forward_respond(role(messages), messages)

  defp forward_respond(:worker, _messages),
    do: {:ok, Message.ai("the detailed worker answer"), usage()}

  defp forward_respond(:supervisor, messages) do
    messages
    |> mentions?("Response from the worker agent")
    |> forward_step()
  end

  defp forward_step(true) do
    call = %Message.ToolCall{name: "forward_message", id: "f1", args: %{"from" => "worker"}}
    {:ok, Message.ai(nil, tool_calls: [call]), usage()}
  end

  defp forward_step(false) do
    call = %Message.ToolCall{name: "transfer_to_worker", id: "t1", args: %{}}
    {:ok, Message.ai(nil, tool_calls: [call]), usage()}
  end

  describe "create/1 response_format" do
    test "decodes the supervisor's final answer into :structured_response" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, opts ->
        response_format_reply(respond_tool?(opts))
      end)

      graph =
        Supervisor.create(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          prompt: "You are supervisor.",
          response_format: %{
            type: "object",
            properties: %{status: %{type: "string"}},
            required: ["status"]
          },
          agents: [
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :worker,
              system_prompt: "You are worker."
            ]
          ]
        )

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("status?")]})

      assert %{active_agent: :supervisor} = state
      assert %{"status" => "resolved"} = state.structured_response
    end
  end

  defp respond_tool?(opts),
    do: opts |> Keyword.get(:tools, []) |> Enum.any?(&(&1.name == "respond"))

  defp response_format_reply(true) do
    call = %Message.ToolCall{name: "respond", id: "s1", args: %{"status" => "resolved"}}
    {:ok, Message.ai(nil, tool_calls: [call]), usage()}
  end

  defp response_format_reply(false), do: {:ok, Message.ai("all handled"), usage()}

  describe "create/1 hierarchical" do
    test "a compiled sub-team acts as a worker" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &hier_script/2)

      subteam =
        LangEx.Prebuilt.Swarm.create(
          default_active_agent: :specialist,
          agents: [
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :specialist,
              system_prompt: "You are the specialist."
            ]
          ]
        )

      graph =
        Supervisor.create(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          prompt: "You are supervisor.",
          agents: [{:subteam, subteam}]
        )

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("handle it")]})

      assert %{active_agent: :supervisor} = state
      assert %Message.AI{content: "all done"} = List.last(state.messages)
      assert mentions?(state.messages, "specialist result")
    end
  end

  defp hier_script(messages, _opts), do: hier_respond(hier_role(messages), messages)

  defp hier_role(messages) do
    Enum.find_value(messages, fn
      %Message.System{content: "You are the specialist."} -> :specialist
      %Message.System{content: "You are supervisor."} -> :supervisor
      _ -> nil
    end)
  end

  defp hier_respond(:specialist, _messages), do: {:ok, Message.ai("specialist result"), usage()}

  defp hier_respond(:supervisor, messages) do
    messages
    |> mentions?("specialist result")
    |> hier_step()
  end

  defp hier_step(true), do: {:ok, Message.ai("all done"), usage()}

  defp hier_step(false) do
    {:ok,
     Message.ai(nil,
       tool_calls: [%Message.ToolCall{name: "transfer_to_subteam", id: "s1", args: %{}}]
     ), usage()}
  end

  describe "create/1 custom state" do
    test "the supervisor shares a reducer-backed custom key, reduced exactly once" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, &notes_script/2)

      graph =
        Supervisor.create(
          state_schema: [notes: {[], fn current, new -> current ++ new end}],
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          prompt: "You are supervisor.",
          tools: [note_tool()],
          agents: [
            [
              provider: LangEx.LLM.OpenAI,
              model: "gpt-4o",
              name: :worker,
              system_prompt: "You are worker."
            ]
          ]
        )

      {:ok, state} = LangEx.invoke(graph, %{messages: [Message.human("note it")]})

      assert %{notes: ["noted"]} = state
      assert %Message.AI{content: "done"} = List.last(state.messages)
    end
  end

  defp notes_script(messages, _opts), do: notes_respond(role(messages), messages)

  defp notes_respond(:supervisor, messages) do
    messages
    |> Enum.any?(&match?(%Message.Tool{tool_call_id: "n1"}, &1))
    |> notes_step()
  end

  defp notes_step(true), do: {:ok, Message.ai("done"), usage()}

  defp notes_step(false) do
    {:ok, Message.ai(nil, tool_calls: [%Message.ToolCall{name: "note", id: "n1", args: %{}}]),
     usage()}
  end

  defp note_tool do
    %LangEx.Tool{
      name: "note",
      description: "Records a note.",
      parameters: %{type: "object", properties: %{}, required: []},
      function: fn _args -> %LangEx.Command{update: %{notes: ["noted"]}} end
    }
  end

  defp parallel_supervisor(opts \\ []) do
    Supervisor.create(
      [
        parallel: true,
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
      ] ++ opts
    )
  end

  defp parallel_script(messages, _opts), do: parallel_respond(two_worker_role(messages), messages)

  defp parallel_respond(:research, _messages), do: {:ok, Message.ai("research done"), usage()}
  defp parallel_respond(:math, _messages), do: {:ok, Message.ai("math done"), usage()}

  defp parallel_respond(:supervisor, messages) do
    {mentions?(messages, "research done"), mentions?(messages, "math done")}
    |> parallel_step()
  end

  defp parallel_step({true, true}), do: {:ok, Message.ai("all complete"), usage()}

  defp parallel_step(_partial) do
    calls = [parallel_transfer(:research, "r1", nil), parallel_transfer(:math, "m1", nil)]
    {:ok, Message.ai(nil, tool_calls: calls), usage()}
  end

  defp parallel_task_script(messages, _opts) do
    parallel_task_respond(two_worker_role(messages), messages)
  end

  defp parallel_task_respond(:research, _messages),
    do: {:ok, Message.ai("research done"), usage()}

  defp parallel_task_respond(:math, _messages), do: {:ok, Message.ai("math done"), usage()}

  defp parallel_task_respond(:supervisor, messages) do
    {mentions?(messages, "research done"), mentions?(messages, "math done")}
    |> parallel_task_step()
  end

  defp parallel_task_step({true, true}), do: {:ok, Message.ai("all complete"), usage()}

  defp parallel_task_step(_partial) do
    calls = [
      parallel_transfer(:research, "r1", "check the logs"),
      parallel_transfer(:math, "m1", "compute the totals")
    ]

    {:ok, Message.ai(nil, tool_calls: calls), usage()}
  end

  defp parallel_transfer(worker, id, nil),
    do: %Message.ToolCall{name: "transfer_to_#{worker}", id: id, args: %{}}

  defp parallel_transfer(worker, id, task),
    do: %Message.ToolCall{
      name: "transfer_to_#{worker}",
      id: id,
      args: %{"task_description" => task}
    }

  defp capture_parallel_view(messages, test_pid) do
    forward_parallel_view(two_worker_role(messages), messages, test_pid)
  end

  defp forward_parallel_view(role, messages, test_pid) when role in [:research, :math],
    do: send(test_pid, {:worker_view, role, messages})

  defp forward_parallel_view(_role, _messages, _test_pid), do: :ok

  defp reply_for(:worker, _messages, _opts), do: raise("worker exploded")
  defp reply_for(_role, messages, opts), do: scripted(messages, opts)

  defp task_scripted(messages, opts), do: task_reply(role(messages), messages, opts)

  defp task_reply(:worker, _messages, _opts), do: {:ok, Message.ai("worker done"), usage()}

  defp task_reply(:supervisor, messages, _opts) do
    messages
    |> mentions?("worker done")
    |> task_turn()
  end

  defp task_turn(true), do: {:ok, Message.ai("all done"), usage()}

  defp task_turn(false) do
    call = %Message.ToolCall{
      name: "transfer_to_worker",
      id: "t1",
      args: %{"task_description" => "investigate the outage"}
    }

    {:ok, Message.ai(nil, tool_calls: [call]), usage()}
  end

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
