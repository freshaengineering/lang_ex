# Team-member interrupts: pause inside a swarm or supervisor member,
# resume on the parent thread.
#
# A member used to surface an inner `interrupt/1` as an error. The
# wrapper now runs the member as a child of the parent: same thread,
# a descended checkpoint namespace, and the interrupt re-thrown so
# the team pauses. Resume the parent with `%Command{resume: value}`
# and the member continues from the call site.
#
# Three scenes, all offline:
#   1. Swarm     — router hands off; refunds pauses for approval
#   2. Supervisor — a worker pauses; the commander finishes after resume
#   3. Wrapper   — a node that ran before the interrupt is not re-run
#
# Tool functions still cannot interrupt (they run in their own tasks).
# Pause from a member node — here, a `post_model_hook`.
#
# Run: elixir examples/scripts/20_team_member_interrupts.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])
Code.require_file("support/in_memory_checkpointer.exs", __DIR__)

defmodule ScriptedTeam do
  @moduledoc "Fake provider driving the three team-interrupt scenes."
  @behaviour LangEx.LLM

  alias LangEx.Message

  @impl true
  def chat(messages, opts) do
    with {:ok, ai, _usage} <- chat_with_usage(messages, opts), do: {:ok, ai}
  end

  @impl true
  def chat_with_usage(messages, _opts) do
    messages
    |> role()
    |> respond(messages)
  end

  defp role(messages) do
    Enum.find_value(messages, fn
      %Message.System{content: "You handle refunds."} -> :refunds
      %Message.System{content: "You route the user."} -> :router
      %Message.System{content: "You investigate."} -> :investigator
      %Message.System{content: "You command the team."} -> :commander
      _ -> nil
    end)
  end

  defp respond(:router, _messages) do
    call = %Message.ToolCall{name: "transfer_to_refunds", id: "handoff_1", args: %{}}
    {:ok, Message.ai(nil, tool_calls: [call]), usage()}
  end

  defp respond(:refunds, _messages) do
    {:ok, Message.ai("Refund $84 to order #4412."), usage()}
  end

  defp respond(:investigator, _messages) do
    {:ok, Message.ai("Root cause: exhausted DB pool after the v2.7.1 deploy."), usage()}
  end

  defp respond(:commander, messages) do
    messages
    |> reported?()
    |> commander_turn()
  end

  defp commander_turn(true) do
    {:ok, Message.ai("Incident closed: recycle the pool, pin the deploy."), usage()}
  end

  defp commander_turn(false) do
    call = %Message.ToolCall{name: "transfer_to_investigator", id: "task_1", args: %{}}
    {:ok, Message.ai(nil, tool_calls: [call]), usage()}
  end

  defp reported?(messages) do
    Enum.any?(messages, fn
      %{content: content} when is_binary(content) -> String.contains?(content, "Root cause")
      _ -> false
    end)
  end

  defp usage, do: %{input_tokens: 20, output_tokens: 8}
end

defmodule TeamInterruptDemo do
  alias Example.InMemoryCheckpointer
  alias LangEx.Command
  alias LangEx.Graph
  alias LangEx.Interrupt
  alias LangEx.Message
  alias LangEx.Prebuilt.Member
  alias LangEx.Prebuilt.Supervisor
  alias LangEx.Prebuilt.Swarm

  def run do
    swarm_scene()
    supervisor_scene()
    wrapper_scene()
  end

  # Router transfers; the refunds member pauses for a human. Resume the
  # swarm thread — not a child thread — and refunds continues.
  defp swarm_scene do
    config = [thread_id: "swarm-refund-1"]
    graph = swarm()

    {:interrupt, {:approve_refund, plan}, _paused} =
      LangEx.invoke(graph, %{messages: [Message.human("I want a refund")]}, config: config)

    IO.puts("swarm paused inside :refunds")
    IO.puts("  review: #{plan}")

    {:ok, state} = LangEx.invoke(graph, %Command{resume: :approve}, config: config)
    IO.puts("swarm resumed on the same thread")
    IO.puts("  active: #{state.active_agent}")
    IO.puts("  answer: #{List.last(state.messages).content}\n")
  end

  # The commander delegates; the investigator pauses. Resume the
  # supervisor thread and the worker's report reaches the commander.
  defp supervisor_scene do
    config = [thread_id: "supervisor-incident-1"]
    graph = supervisor()

    {:interrupt, {:approve_finding, finding}, _paused} =
      LangEx.invoke(graph, %{messages: [Message.human("checkout is 500ing")]}, config: config)

    IO.puts("supervisor paused inside :investigator")
    IO.puts("  review: #{finding}")

    {:ok, state} = LangEx.invoke(graph, %Command{resume: :approve}, config: config)
    IO.puts("supervisor resumed on the same thread")
    IO.puts("  active: #{state.active_agent}")
    IO.puts("  answer: #{List.last(state.messages).content}\n")
  end

  # A node that finished before the interrupt must not run again on
  # resume. The member inherits the parent's checkpointer and continues
  # from its namespaced checkpoint.
  defp wrapper_scene do
    {:ok, prep_runs} = Agent.start_link(fn -> 0 end)
    config = [thread_id: "member-wrapper-1"]
    graph = wrapping_parent(prep_runs)

    {:interrupt, :review, _paused} =
      LangEx.invoke(graph, %{messages: [Message.human("draft the reply")]}, config: config)

    IO.puts("member wrapper paused after :prep")

    {:ok, state} = LangEx.invoke(graph, %Command{resume: :ok}, config: config)
    IO.puts("member wrapper resumed; :prep ran #{Agent.get(prep_runs, & &1)} time(s)")
    IO.puts("  answer: #{List.last(state.messages).content}")
  end

  defp swarm do
    Swarm.create(
      agents: [
        [
          provider: ScriptedTeam,
          model: "scripted-1",
          name: :router,
          system_prompt: "You route the user."
        ],
        [
          provider: ScriptedTeam,
          model: "scripted-1",
          name: :refunds,
          system_prompt: "You handle refunds.",
          post_model_hook: &review(&1, :approve_refund)
        ]
      ],
      default_active_agent: :router,
      checkpointer: InMemoryCheckpointer
    )
  end

  defp supervisor do
    Supervisor.create(
      provider: ScriptedTeam,
      model: "scripted-1",
      prompt: "You command the team.",
      checkpointer: InMemoryCheckpointer,
      agents: [
        [
          provider: ScriptedTeam,
          model: "scripted-1",
          name: :investigator,
          system_prompt: "You investigate.",
          post_model_hook: &review(&1, :approve_finding)
        ]
      ]
    )
  end

  defp wrapping_parent(prep_runs) do
    member =
      Graph.new(messages: {[], &Message.add_messages/2}, active_agent: :drafter)
      |> Graph.add_node(:prep, fn _state ->
        prep_runs
        |> Agent.update(&(&1 + 1))
        |> then(fn _ -> %{messages: [Message.ai("draft ready")]} end)
      end)
      |> Graph.add_node(:ask, fn _state ->
        :review
        |> Interrupt.interrupt()
        |> then(fn _approved -> %{} end)
      end)
      |> Graph.add_edge(:__start__, :prep)
      |> Graph.add_edge(:prep, :ask)
      |> Graph.add_edge(:ask, :__end__)
      |> Graph.compile()

    Graph.new(messages: {[], &Message.add_messages/2}, active_agent: :drafter)
    |> Graph.add_node(:drafter, Member.node(member, :drafter, :full_history))
    |> Graph.add_edge(:__start__, :drafter)
    |> Graph.add_edge(:drafter, :__end__)
    |> Graph.compile(name: :wrapped_member, checkpointer: InMemoryCheckpointer)
  end

  defp review(update, kind) do
    update.messages
    |> List.last()
    |> payload(kind)
    |> Interrupt.interrupt()
    |> then(fn _approved -> update end)
  end

  defp payload(%Message.AI{content: content}, kind) when is_binary(content), do: {kind, content}
  defp payload(_message, kind), do: {kind, nil}
end

TeamInterruptDemo.run()
