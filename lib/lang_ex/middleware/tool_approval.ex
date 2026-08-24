defmodule LangEx.Middleware.ToolApproval do
  @moduledoc """
  Middleware that puts a human between the model and its risky tool calls.

  An agent that can page an on-call engineer, restart a service, or delete a
  record needs a review step on exactly those calls and nowhere else. Each
  guarded call the model requests pauses the graph with a description of what
  it wants to do; the reviewer's answer decides whether it runs, runs with
  corrected arguments, or is refused.

  Review happens in its own graph node (`:before_tools`), so resuming
  re-runs only the review — the model call whose requests are being reviewed
  is not repeated, and the reviewer's decision applies to the calls they
  actually saw.

  Unguarded calls in the same batch run untouched, and a refusal does not
  block the calls beside it: a refused call is answered with an error tool
  result the model can react to, while the approved ones execute.

  ## Options

  - `:tools` — names of the tools that need approval, or `:all` for every
    tool. Default `[]`, which makes the middleware a no-op.
  - `:describe` — `(tool_call, state -> term())` building the payload
    surfaced to the reviewer. Defaults to a map of the tool name, arguments
    and call ID.
  - `:messages_key` — state key holding the conversation (default
    `:messages`).

  ## Deciding

  Resume with one of:

  - `:approve` — run the call as the model requested it
  - `{:approve, args}` — run it with `args` instead (fix a typo'd path, narrow
    a query)
  - `:reject` / `{:reject, reason}` — refuse it; the model is told why and
    can choose differently
  - `{:respond, content}` — answer the call yourself without running the
    tool

  ## Example

      graph =
        LangEx.Prebuilt.agent(
          model: "claude-sonnet-5",
          tools: [read_logs, restart_service],
          middleware: [ToolApproval.new(tools: ["restart_service"])],
          checkpointer: LangEx.Checkpointer.Memory
        )

      config = [configurable: [thread_id: "ops-42"]]

      {:ok, %{__interrupt__: %{tool: "restart_service", args: args}}} =
        LangEx.invoke(graph, %{messages: [Message.human("api is wedged")]},
          config: config
        )

      LangEx.invoke(graph, %Command{resume: {:approve, %{args | "graceful" => true}}},
        config: config
      )
  """

  alias LangEx.Interrupt
  alias LangEx.Message
  alias LangEx.Middleware
  alias LangEx.Tool

  @refusal "Refused by reviewer"
  @edits_key :__reviewed_tool_args__

  @doc "Builds a tool-approval middleware. See the module doc for options."
  @spec new(keyword()) :: Middleware.t()
  def new(opts \\ []) do
    Middleware.new(
      name: :tool_approval,
      before_tools: hook(opts),
      wrap_tool_call: &apply_corrections/2,
      state_schema: [{@edits_key, %{}}]
    )
  end

  defp hook(opts) do
    guard = Keyword.get(opts, :tools, [])
    describe = Keyword.get(opts, :describe, &default_description/2)
    messages_key = Keyword.get(opts, :messages_key, :messages)

    fn state -> review(state, guard, describe, messages_key) end
  end

  defp review(state, guard, describe, messages_key) do
    pending = state |> Map.get(messages_key, []) |> Tool.Node.pending_calls()

    pending
    |> Enum.filter(&guarded?(&1, guard))
    |> Enum.map(&{&1, Interrupt.interrupt(describe.(&1, state))})
    |> settle(pending, messages_key)
  end

  defp guarded?(_call, :all), do: true
  defp guarded?(call, names) when is_list(names), do: call.name in names

  # An approved call is left for the tools node to run; a decided one is
  # answered here, which is what makes the tools node skip it.
  defp settle(decisions, pending, messages_key) do
    replies = Enum.flat_map(decisions, &reply/1)

    pending
    |> remaining(replies)
    |> update(replies, corrections(decisions), messages_key)
  end

  defp reply({call, {:reject, reason}}), do: [Message.tool_error(refusal(reason), call.id)]
  defp reply({call, :reject}), do: [Message.tool_error(@refusal <> ".", call.id)]
  defp reply({call, {:respond, content}}), do: [Message.tool(content, call.id)]
  defp reply({_call, :approve}), do: []
  defp reply({_call, {:approve, args}}) when is_map(args), do: []
  defp reply({call, decision}), do: raise_unknown(call, decision)

  # Corrected arguments travel in state keyed by call ID and are applied when
  # the call executes, so history keeps showing what the model asked for and
  # what the reviewer changed stays reconstructable.
  defp corrections(decisions) do
    decisions
    |> Enum.filter(&match?({_call, {:approve, args}} when is_map(args), &1))
    |> Map.new(fn {call, {:approve, args}} -> {call.id, args} end)
  end

  defp apply_corrections(request, execute) do
    request.state
    |> Map.get(@edits_key, %{})
    |> Map.fetch(request.tool_call.id)
    |> correct(request)
    |> execute.()
  end

  defp correct({:ok, args}, request), do: put_in(request.tool_call.args, args)
  defp correct(:error, request), do: request

  defp remaining(pending, replies) do
    answered = MapSet.new(replies, & &1.tool_call_id)
    Enum.reject(pending, &MapSet.member?(answered, &1.id))
  end

  # Nothing left to execute means the model must hear the outcome itself,
  # rather than the run ending on an unanswered request.
  defp update([], replies, corrections, messages_key),
    do: %{
      messages_key => replies,
      @edits_key => corrections,
      Middleware.jump_key() => :model
    }

  defp update([_ | _], replies, corrections, messages_key),
    do: %{messages_key => replies, @edits_key => corrections}

  defp refusal(reason), do: "#{@refusal}: #{reason}"

  defp default_description(call, _state),
    do: %{type: :tool_approval, tool: call.name, args: call.args, tool_call_id: call.id}

  defp raise_unknown(call, decision) do
    raise ArgumentError,
          "ToolApproval: cannot act on #{inspect(decision)} for #{call.name} — resume with " <>
            ":approve, {:approve, args}, :reject, {:reject, reason}, or {:respond, content}"
  end
end
