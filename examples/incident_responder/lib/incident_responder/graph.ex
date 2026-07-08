defmodule IncidentResponder.Graph do
  @moduledoc """
  LangEx state graph for the incident responder.

  Uses the new `ToolNode` pattern for diagnostic and action tool calls.

      __start__ -> greet -> await_input (INTERRUPT)
      await_input -> router
      router -> {answer_question, triage_incident, goodbye}
      answer_question -> await_input (loop)
      triage_incident -> {await_input (needs_input), execute_action (ready)}
      execute_action -> {await_input (success), escalate (failure)}
      goodbye -> __end__
      escalate -> __end__
  """

  alias IncidentResponder.Prompts
  alias IncidentResponder.Tools
  alias LangEx.Graph
  alias LangEx.Message
  alias LangEx.MessagesState
  alias LangEx.Tool.Node, as: ToolNode

  @model "claude-opus-4-20250514"
  @max_retries 2
  @retry_base_ms 2_000

  def build(opts \\ []) do
    MessagesState.schema(
      phase: :greeting,
      last_response: nil,
      action: nil,
      action_result: nil,
      action_history: []
    )
    |> Graph.new()
    |> Graph.add_node(:greet, &greet/1)
    |> Graph.add_node(:await_input, &await_input/1)
    |> Graph.add_node(:router, &route/1)
    |> Graph.add_node(:answer_question, &answer_question/1)
    |> Graph.add_node(:triage_incident, &triage_incident/1)
    |> Graph.add_node(:execute_action, &execute_action/1)
    |> Graph.add_node(:goodbye, &goodbye/1)
    |> Graph.add_node(:escalate, &escalate/1)
    |> Graph.add_edge(:__start__, :greet)
    |> Graph.add_edge(:greet, :await_input)
    |> Graph.add_edge(:await_input, :router)
    |> Graph.add_conditional_edges(:router, &route_intent/1, %{
      "question" => :answer_question,
      "incident" => :triage_incident,
      "goodbye" => :goodbye
    })
    |> Graph.add_edge(:answer_question, :await_input)
    |> Graph.add_conditional_edges(:triage_incident, &action_ready/1, %{
      "await_input" => :await_input,
      "execute_action" => :execute_action
    })
    |> Graph.add_conditional_edges(:execute_action, &action_result/1, %{
      "success" => :await_input,
      "failure" => :escalate
    })
    |> Graph.add_edge(:goodbye, :__end__)
    |> Graph.add_edge(:escalate, :__end__)
    |> Graph.compile(opts)
  end

  defp greet(_state) do
    ai =
      chat_with_retry(
        [
          Message.system(Prompts.main_system_prompt()),
          Message.human("An engineer has just connected to incident response. Greet them briefly and ask what's going on.")
        ],
        model: @model,
        temperature: 0.3
      )

    %{messages: [ai], last_response: ai.content, phase: :greeting}
  end

  defp await_input(state) do
    user_message = LangEx.Interrupt.interrupt(%{response: state.last_response})
    %{messages: [Message.human(user_message)]}
  end

  defp current_phase(state), do: state.phase |> to_string()

  defp route(state) do
    case current_phase(state) do
      "incident" -> %{phase: :incident}
      _ -> classify_intent(state)
    end
  end

  defp classify_intent(state) do
    recent = recent_context(state, 6)

    phase_hint =
      case current_phase(state) do
        "question" -> "The conversation is currently answering questions."
        "greeting" -> "The conversation just started."
        "incident" -> "An incident is being triaged."
        other -> "Current phase: #{other}."
      end

    ai =
      chat_with_retry(
        [Message.system(Prompts.router_prompt(phase_hint)) | recent],
        model: @model,
        temperature: 0.0
      )

    intent =
      ai.content
      |> String.trim()
      |> String.downcase()
      |> normalize_intent()

    %{phase: String.to_atom(intent)}
  end

  defp answer_question(state) do
    conversation = conversation_messages(state)

    ai =
      chat_with_retry(
        [Message.system(Prompts.answer_question_prompt()) | conversation],
        model: @model,
        temperature: 0.3
      )

    %{messages: [ai], last_response: ai.content, phase: :question}
  end

  defp triage_incident(state) do
    conversation = conversation_messages(state)
    history = state[:action_history] || []
    tools = Tools.tool_declarations()

    tool_node_fn = ToolNode.node(tools)

    ai =
      chat_with_retry(
        [Message.system(Prompts.triage_incident_prompt(history)) | conversation],
        model: @model,
        temperature: 0.3,
        tools: tools
      )

    {messages, final_ai} = run_tool_loop(ai, conversation, tools, tool_node_fn, state)

    action = detect_action_readiness(final_ai, state)
    updated_history = record_action(final_ai.content, history)

    %{
      messages: messages ++ [final_ai],
      last_response: final_ai.content,
      phase: :incident,
      action: action,
      action_history: updated_history
    }
  end

  defp run_tool_loop(%Message.AI{tool_calls: [_ | _]} = ai, conversation, tools, tool_node_fn, state) do
    tool_state = %{messages: conversation ++ [ai]}
    %{messages: tool_results} = tool_node_fn.(tool_state)

    updated_conversation = conversation ++ [ai | tool_results]

    next_ai =
      chat_with_retry(
        [Message.system(Prompts.triage_incident_prompt(state[:action_history] || [])) | updated_conversation],
        model: @model,
        temperature: 0.3,
        tools: tools
      )

    case next_ai do
      %Message.AI{tool_calls: [_ | _]} ->
        {inner_msgs, final} = run_tool_loop(next_ai, updated_conversation, tools, tool_node_fn, state)
        {[ai | tool_results] ++ inner_msgs, final}

      _ ->
        {[ai | tool_results], next_ai}
    end
  end

  defp run_tool_loop(ai, _conversation, _tools, _tool_node_fn, _state), do: {[], ai}

  defp execute_action(state) do
    action = state.action || %{}
    tools = Tools.tool_declarations()
    tool_node_fn = ToolNode.node(tools)

    {tool_name, tool_args} = build_action_call(action)

    action_call = %Message.ToolCall{
      name: tool_name,
      id: "exec_#{System.unique_integer([:positive])}",
      args: tool_args
    }

    ai_with_call = Message.ai(nil, tool_calls: [action_call])
    tool_state = %{messages: [ai_with_call]}
    %{messages: [tool_result]} = tool_node_fn.(tool_state)

    case Jason.decode(tool_result.content) do
      {:ok, %{"success" => true} = res} ->
        confirmation = Message.ai(res["message"] || "Action completed successfully.")
        %{messages: [ai_with_call, tool_result, confirmation], last_response: confirmation.content, action_result: :success, phase: :greeting}

      _ ->
        %{action_result: :failure}
    end
  end

  defp build_action_call(%{type: :restart, service: service, reason: reason}) do
    {"restart_service", %{"service" => service, "reason" => reason || "incident triage"}}
  end

  defp build_action_call(%{type: :page, severity: sev, service: service, summary: summary}) do
    {"page_oncall", %{"severity" => sev || "SEV2", "service" => service, "summary" => summary || "Incident in progress"}}
  end

  defp build_action_call(%{type: :status_page, service: service, status: status, message: message}) do
    {"update_status_page", %{"service" => service, "status" => status || "investigating", "message" => message || "We are investigating the issue."}}
  end

  defp build_action_call(action) do
    service = action[:service] || "unknown"
    {"restart_service", %{"service" => service, "reason" => "incident triage — automated action"}}
  end

  defp goodbye(state) do
    conversation = conversation_messages(state)

    ai =
      chat_with_retry(
        [Message.system(Prompts.goodbye_prompt()) | conversation],
        model: @model,
        temperature: 0.5
      )

    %{messages: [ai], last_response: ai.content, phase: :goodbye}
  end

  defp escalate(_state) do
    msg =
      Message.ai(
        "I wasn't able to resolve this automatically. " <>
          "Reach Sarah Kim (primary on-call) at +1-555-0101 or post in #incidents on Slack."
      )

    %{messages: [msg], last_response: msg.content, phase: :escalate}
  end

  defp route_intent(state), do: to_string(state.phase)

  defp action_ready(state) do
    case state.action do
      %{ready: true} -> "execute_action"
      _ -> "await_input"
    end
  end

  defp action_result(state) do
    case state.action_result do
      :success -> "success"
      _ -> "failure"
    end
  end

  # Retries, backoff, and the fallback message are handled by
  # LangEx.LLM.Resilient — no hand-rolled retry loop needed.
  defp chat_with_retry(messages, opts) do
    {:ok, ai} =
      LangEx.LLM.Resilient.chat(
        LangEx.LLM.Anthropic,
        messages,
        opts ++
          [
            max_retries: @max_retries,
            retry_base_ms: @retry_base_ms,
            on_retry: &log_retry/4,
            fallback: &fallback_message/0
          ]
      )

    ai
  end

  defp log_retry(_attempt, _elapsed_ms, wait_ms, reason) do
    IO.puts(
      "  [#{LangEx.LLM.Resilient.format_error(reason)} — retrying in #{div(wait_ms, 1000)}s...]"
    )
  end

  defp fallback_message do
    Message.ai("Sorry, I'm having a technical issue right now. Could you try again?")
  end

  @intent_patterns [
    {"incident", ~w(incident alert outage down)},
    {"question", ~w(question)},
    {"goodbye", ~w(goodbye bye done resolved)}
  ]

  defp normalize_intent(text) do
    @intent_patterns
    |> Enum.find(fn {_, patterns} -> Enum.any?(patterns, &(text =~ &1)) end)
    |> extract_intent()
  end

  defp extract_intent({intent, _patterns}), do: intent
  defp extract_intent(nil), do: "question"

  defp recent_context(state, max_messages) do
    state.messages
    |> Enum.filter(&has_content?/1)
    |> Enum.take(-max_messages)
  end

  defp conversation_messages(state) do
    Enum.filter(state.messages, &has_content?/1)
  end

  defp has_content?(%Message.Human{}), do: true
  defp has_content?(%Message.AI{}), do: true
  defp has_content?(%Message.Tool{}), do: true
  defp has_content?(%{tool_calls: [_ | _]}), do: true
  defp has_content?(%{tool_call_id: _}), do: true
  defp has_content?(%{content: c}) when is_binary(c), do: true
  defp has_content?(_), do: false

  defp record_action(content, history) when is_binary(content) do
    content
    |> String.downcase()
    |> action_content?()
    |> append_action(content, history)
  end

  defp record_action(_, history), do: history

  defp action_content?(lower) do
    lower =~ "restarted" or lower =~ "paged" or lower =~ "status page updated" or
      lower =~ "rolling restart" or lower =~ "incident created"
  end

  defp append_action(true, content, history), do: history ++ [content]
  defp append_action(false, _content, history), do: history

  defp detect_action_readiness(ai, state) do
    existing = state.action || %{}

    ai.content
    |> Kernel.||("")
    |> String.downcase()
    |> confirmation_ask?()
    |> apply_readiness(existing)
  end

  defp confirmation_ask?(content) do
    content =~ "shall i restart" or content =~ "should i restart" or
      content =~ "want me to restart" or content =~ "shall i page" or
      content =~ "should i page" or content =~ "want me to page" or
      content =~ "shall i update" or content =~ "confirm"
  end

  defp apply_readiness(true, existing), do: Map.put(existing, :ready, false)
  defp apply_readiness(false, existing), do: existing
end
