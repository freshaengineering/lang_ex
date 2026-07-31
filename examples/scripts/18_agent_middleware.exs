# An agent you would let near production: reviewed, bounded, resilient.
#
# Four middleware stack around the same agent, each owning one concern:
#
#   ToolApproval  a human decides on the risky tool, and may correct its args
#   ToolRetry     a transient tool failure is retried before the model sees it
#   CallBudget    a run that will not converge stops instead of spending
#   ModelRequest  a wrap_model_call hook rewrites the request per turn
#
# Plus the run-scoped `before_agent` / `after_agent` hooks, which fire once
# per run rather than once per turn.
#
# A scripted provider stands in for a real LLM, so this runs without keys.
#
# Run: elixir examples/scripts/18_agent_middleware.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule ScriptedOps do
  @moduledoc """
  Fake provider driving an on-call scenario: read the logs, restart the
  service, then report. Records which model each turn was asked of.
  """
  @behaviour LangEx.LLM

  alias LangEx.Message

  @impl true
  def chat(messages, opts) do
    with {:ok, ai, _usage} <- chat_with_usage(messages, opts), do: {:ok, ai}
  end

  @impl true
  def chat_with_usage(messages, opts) do
    record_model(opts)

    messages
    |> Enum.filter(&match?(%Message.Tool{}, &1))
    |> length()
    |> reply()
  end

  defp reply(0), do: {:ok, call("read_logs", "c1", %{"service" => "api"}), usage()}

  defp reply(1),
    do: {:ok, call("restart_service", "c2", %{"service" => "api", "graceful" => false}), usage()}

  defp reply(_answered),
    do: {:ok, Message.ai("api was wedged on a connection leak; restarted gracefully."), usage()}

  defp call(name, id, args) do
    Message.ai(nil, tool_calls: [%Message.ToolCall{name: name, id: id, args: args}])
  end

  defp usage, do: %{input_tokens: 120, output_tokens: 30}

  defp record_model(opts) do
    :persistent_term.put(:models, :persistent_term.get(:models, []) ++ [opts[:model]])
  end
end

defmodule OpsAgentDemo do
  alias LangEx.Command
  alias LangEx.Message
  alias LangEx.Middleware
  alias LangEx.Middleware.CallBudget
  alias LangEx.Middleware.ModelRequest
  alias LangEx.Middleware.ToolApproval
  alias LangEx.Middleware.ToolRetry
  alias LangEx.Prebuilt
  alias LangEx.Tool

  @config [thread_id: "ops-42"]

  def run do
    agent = build()

    # The model asks to read the logs; that tool fails once and is retried
    # inside the call, so the model never learns it flaked. Then it asks to
    # restart the service — a guarded tool, so the run pauses for review.
    {:interrupt, review, _state} =
      LangEx.invoke(agent, %{messages: [Message.human("api is wedged")]}, config: @config)

    IO.puts("paused for review: #{review.tool} #{inspect(review.args)}")

    # Approve, but insist on a graceful restart. The correction is applied
    # when the call executes; history still shows what the model asked for.
    {:ok, result} =
      LangEx.invoke(
        agent,
        %Command{resume: {:approve, Map.put(review.args, "graceful", true)}},
        config: @config
      )

    IO.puts("restart ran with:  #{inspect(:persistent_term.get(:restart_args))}")
    IO.puts("read_logs attempts: #{:persistent_term.get(:log_attempts)}")
    IO.puts("answer: #{List.last(result.messages).content}")

    # `before_agent`/`after_agent` fired once for the run, not once per turn,
    # even though the run spans a pause and three model calls.
    IO.puts("\nrun hooks: #{inspect(result.audit)}")
    IO.puts("model per turn: #{inspect(:persistent_term.get(:models))}")

    budget_demo()
  end

  # A model that always asks for another tool call would loop forever. The
  # budget ends the run, answers the dangling call so the transcript stays
  # valid, and flags why it stopped.
  defp budget_demo do
    {:ok, result} =
      LangEx.invoke(looping_agent(), %{messages: [Message.human("keep digging")]},
        config: [thread_id: "ops-loop"]
      )

    IO.puts("\nmodel calls made: #{result.model_calls}")
    IO.puts("stopped by budget: #{result.budget_exhausted}")
    IO.puts("last message: #{List.last(result.messages).content}")
  end

  defp build do
    Prebuilt.agent(
      provider: ScriptedOps,
      model: "scripted-small",
      tools: [read_logs(), restart_service()],
      system_prompt: "You are an on-call engineer.",
      middleware: [
        audit_trail(),
        escalate_for_the_summary(),
        ToolApproval.new(tools: ["restart_service"]),
        ToolRetry.new(max_attempts: 3, backoff: 5, tools: ["read_logs"]),
        CallBudget.new(max_model_calls: 10)
      ],
      name: :ops_agent,
      checkpointer: LangEx.Checkpointer.Memory
    )
  end

  defp looping_agent do
    Prebuilt.agent(
      provider: ScriptedOps,
      model: "scripted-small",
      tools: [read_logs()],
      middleware: [CallBudget.new(max_model_calls: 2)],
      name: :looping_agent
    )
  end

  # Run-scoped hooks: setup and teardown that must not repeat every turn.
  defp audit_trail do
    Middleware.new(
      name: :audit,
      state_schema: [audit: {[], &Kernel.++/2}],
      before_agent: fn _state -> %{audit: ["opened"]} end,
      after_agent: fn state -> %{audit: ["closed after #{state.model_calls} model calls"]} end
    )
  end

  # A wrap_model_call hook rewrites the request rather than the state: the
  # cheap model drives the tool work, a stronger one writes the summary.
  defp escalate_for_the_summary do
    Middleware.new(
      name: :escalate,
      wrap_model_call: fn request, next ->
        request
        |> ModelRequest.override(model: model_for(request))
        |> next.()
      end
    )
  end

  defp model_for(request) do
    request.messages
    |> Enum.any?(&match?(%Message.Tool{tool_call_id: "c2"}, &1))
    |> summary_model()
  end

  # A bare string lets the provider be inferred from the model name; the
  # `{provider, model}` form names it, which is what a fake provider needs.
  defp summary_model(true), do: {ScriptedOps, "scripted-large"}
  defp summary_model(false), do: {ScriptedOps, "scripted-small"}

  defp read_logs do
    %Tool{
      name: "read_logs",
      description: "Read recent logs for a service",
      parameters: %{
        type: "object",
        properties: %{service: %{type: "string"}},
        required: ["service"]
      },
      function: &fetch_logs/1
    }
  end

  # Fails the first time, like a log API under load.
  defp fetch_logs(%{"service" => service}) do
    attempts = :persistent_term.get(:log_attempts, 0) + 1
    :persistent_term.put(:log_attempts, attempts)
    flake(attempts)
    "#{service}: 4xx spike, connection pool exhausted"
  end

  defp flake(1), do: raise("log backend timed out")
  defp flake(_later), do: :ok

  defp restart_service do
    %Tool{
      name: "restart_service",
      description: "Restart a service",
      parameters: %{
        type: "object",
        properties: %{service: %{type: "string"}, graceful: %{type: "boolean"}},
        required: ["service"]
      },
      function: &restart/1
    }
  end

  defp restart(args) do
    :persistent_term.put(:restart_args, args)
    "restarted #{args["service"]}"
  end
end

OpsAgentDemo.run()
