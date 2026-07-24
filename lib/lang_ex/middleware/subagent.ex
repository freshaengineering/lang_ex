defmodule LangEx.Middleware.Subagent do
  @moduledoc """
  Middleware that lets the agent delegate work to ephemeral subagents.

  Contributes a `task` tool through which the main agent spawns a
  context-isolated child agent: the child sees nothing of the parent
  conversation, works through its own tool-calling loop, and hands back
  only its final report as the tool reply. This keeps deep-dive work
  (log mining, research, drafting) out of the parent's context window.

  Children are ephemeral: each call compiles a fresh child graph with
  `LangEx.Prebuilt.agent/1` — no checkpointer, no middleware (so a child
  cannot spawn subagents of its own) — and the child's conversation is
  discarded when it finishes. Only the report survives, in the tool
  reply; the child's token usage is folded into the parent's
  `:llm_usage`.

  ## Options

  - `:subagents` (required) - list of subagent spec maps:
    - `:name` (required) - the `subagent_type` value the model passes
    - `:description` (required) - shown to the model in the tool description
    - `:system_prompt` (required) - the child agent's system prompt
    - `:tools` - tools for the child, a list or `fn state -> tools end`
      (default `[]`)
    - `:inherit_keys` - parent-state keys copied into the child's input
      state (default `[]`) — lets state-derived child tools (sessions,
      serialized tool specs, time windows) materialize inside the child
      without exposing the parent conversation
    - `:provider` / `:model` - override the middleware-level defaults
    - `:recursion_limit` - max child super-steps (default `24`)
  - `:provider` / `:model` - defaults for children without their own

  ## Example

      LangEx.Prebuilt.agent(
        model: "claude-sonnet-5",
        middleware: [
          LangEx.Middleware.Subagent.new(
            subagents: [
              %{
                name: "log-miner",
                description: "Deep-dives logs to find root causes.",
                system_prompt: "You are a log analysis expert...",
                tools: [logs_tool]
              }
            ],
            provider: LangEx.LLM.Anthropic,
            model: "claude-sonnet-5"
          )
        ]
      )
  """

  alias LangEx.Command
  alias LangEx.Message
  alias LangEx.Middleware
  alias LangEx.Prebuilt
  alias LangEx.Tool

  @default_recursion_limit 24
  @no_answer "Subagent returned no answer"

  @doc "Builds a subagent-spawning middleware. See the module doc for options."
  @spec new(keyword()) :: Middleware.t()
  def new(opts) do
    opts
    |> Keyword.fetch!(:subagents)
    |> Enum.map(&build_spec(&1, opts))
    |> then(&Middleware.new(name: :subagent, tools: [task_tool(&1)]))
  end

  defp build_spec(subagent, opts) do
    %{
      name: Map.fetch!(subagent, :name),
      description: Map.fetch!(subagent, :description),
      system_prompt: Map.fetch!(subagent, :system_prompt),
      tools: Map.get(subagent, :tools, []),
      provider: Map.get(subagent, :provider, Keyword.get(opts, :provider)),
      model: Map.get(subagent, :model, Keyword.get(opts, :model)),
      recursion_limit: Map.get(subagent, :recursion_limit, @default_recursion_limit),
      inherit_keys: Map.get(subagent, :inherit_keys, [])
    }
  end

  defp task_tool(specs) do
    %Tool{
      name: "task",
      description: task_description(specs),
      parameters: task_parameters(specs),
      function: &run_task(&1, &2, specs)
    }
  end

  defp task_description(specs) do
    "Launch an ephemeral subagent to handle a delegated task in an isolated context. " <>
      "The subagent sees NOTHING of this conversation, so the description must be a " <>
      "fully self-contained brief carrying every detail it needs. The subagent works " <>
      "autonomously and returns only its final report.\n\nAvailable subagent types:\n" <>
      Enum.map_join(specs, "\n", &"- #{&1.name}: #{&1.description}")
  end

  defp task_parameters(specs) do
    %{
      "type" => "object",
      "properties" => %{
        "description" => %{
          "type" => "string",
          "description" =>
            "The full task brief for the subagent. Must be self-contained: the " <>
              "subagent sees nothing of the parent conversation."
        },
        "subagent_type" => %{
          "type" => "string",
          "enum" => Enum.map(specs, & &1.name),
          "description" => "The type of subagent to launch."
        }
      },
      "required" => ["description", "subagent_type"]
    }
  end

  defp run_task(
         %{"description" => brief, "subagent_type" => type},
         %{tool_call_id: id, state: parent_state},
         specs
       ) do
    specs
    |> Enum.find(&(&1.name == type))
    |> launch(brief, id, type, specs, parent_state)
  end

  defp launch(nil, _brief, _id, type, specs, _parent_state),
    do: "Unknown subagent_type: #{type}. Available: #{Enum.map_join(specs, ", ", & &1.name)}"

  defp launch(spec, brief, id, _type, _specs, parent_state) do
    spec
    |> child_graph()
    |> LangEx.invoke(child_input(spec, brief, parent_state),
      recursion_limit: spec.recursion_limit
    )
    |> child_reply(spec, id)
  end

  defp child_input(spec, brief, parent_state) do
    parent_state
    |> Map.take(spec.inherit_keys)
    |> Map.put(:messages, [Message.human(brief)])
  end

  # Compiled lazily per call: children hold no state worth caching and a
  # fresh graph avoids serializing tool closures into parent checkpoints.
  defp child_graph(spec) do
    [
      system_prompt: spec.system_prompt,
      tools: spec.tools,
      provider: spec.provider,
      model: spec.model,
      resilient: true
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Prebuilt.agent()
  end

  defp child_reply({:ok, final}, _spec, id) do
    %Command{
      update: %{
        llm_usage: Map.get(final, :llm_usage, %{}),
        messages: [final.messages |> final_report() |> Message.tool(id)]
      }
    }
  end

  defp child_reply({:error, reason}, spec, _id),
    do: "Subagent #{spec.name} failed: " <> inspect(reason)

  defp final_report(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&match?(%Message.AI{}, &1))
    |> report_content()
  end

  defp report_content(%Message.AI{content: content}) when is_binary(content) and content != "",
    do: content

  defp report_content(_message), do: @no_answer
end
