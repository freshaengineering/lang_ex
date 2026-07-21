defmodule LangEx.Prebuilt.Reflect do
  @moduledoc """
  A generate → critique → revise loop (the reflection / reflexion pattern).

  `create/1` compiles a graph that drafts an answer, has a critic evaluate
  it against `:reflect_prompt`, and loops back to revise while the critic
  withholds approval — up to `:max_iterations`. The critic's verdict is
  obtained with `LangEx.LLM.ChatModel.structured/2`, so approval is a
  validated boolean rather than parsed prose.

      graph =
        LangEx.Prebuilt.Reflect.create(
          model: "claude-opus-4-20250514",
          generate_prompt: "Draft a runbook step for the incident.",
          reflect_prompt: "Critique the draft. Approve only if it is correct and complete.",
          max_iterations: 3
        )

      {:ok, %{messages: messages}} =
        LangEx.invoke(graph, %{messages: [LangEx.Message.human("DB CPU at 100%")]})

  Graph state adds `:reflect_iteration`, `:reflect_approved`, and
  `:reflect_feedback` to the standard `:messages` / `:llm_usage` channels.
  """

  alias LangEx.Graph
  alias LangEx.LLM.ChatModel
  alias LangEx.Message

  @reflect_opt_keys [
    :name,
    :generate_prompt,
    :reflect_prompt,
    :max_iterations,
    :checkpointer,
    :compaction
  ]

  @default_reflect_prompt "You are a critic. Evaluate the assistant's most recent answer. " <>
                            "Approve it only when it is correct, complete, and well-supported. " <>
                            "Otherwise, give specific, actionable feedback for a revision."

  @critique_schema %{
    "type" => "object",
    "properties" => %{
      "approved" => %{
        "type" => "boolean",
        "description" => "true when the answer needs no further revision"
      },
      "feedback" => %{
        "type" => "string",
        "description" => "specific guidance for the next revision when not approved"
      }
    },
    "required" => ["approved"]
  }

  @doc """
  Builds and compiles a reflection graph.

  ## Options

  - `:model` / `:provider` - forwarded to the LLM (one is required)
  - `:generate_prompt` - system prompt for the drafting step
  - `:reflect_prompt` - system prompt for the critic (has a sensible default)
  - `:max_iterations` - hard cap on revise rounds (default `3`)
  - `:name` - graph name for telemetry (default `:reflect`)
  - `:checkpointer` - enables persistence and resume
  - `:compaction` - context compaction options; `false` disables
  - All other options (`:resilient`, `:temperature`, `:api_key`, ...) are
    forwarded to the underlying LLM calls
  """
  @spec create(keyword()) :: Graph.Compiled.t()
  def create(opts) do
    {reflect_opts, llm_opts} = Keyword.split(opts, @reflect_opt_keys)
    max = Keyword.get(reflect_opts, :max_iterations, 3)

    Graph.new(
      messages: {[], &Message.add_messages/2},
      llm_usage: {%{}, &ChatModel.merge_usage/2},
      reflect_iteration: 0,
      reflect_approved: false,
      reflect_feedback: nil
    )
    |> Graph.add_node(:generate, generate_node(llm_opts, reflect_opts))
    |> Graph.add_node(:reflect, reflect_node(llm_opts, reflect_opts))
    |> Graph.add_edge(:__start__, :generate)
    |> Graph.add_edge(:generate, :reflect)
    |> Graph.add_conditional_edges(:reflect, &route(&1, max), %{
      revise: :generate,
      done: :__end__
    })
    |> Graph.compile(
      name: Keyword.get(reflect_opts, :name, :reflect),
      checkpointer: Keyword.get(reflect_opts, :checkpointer)
    )
  end

  defp generate_node(llm_opts, reflect_opts) do
    chat = ChatModel.node(llm_opts)
    prompt = Keyword.get(reflect_opts, :generate_prompt)

    fn state ->
      state.messages
      |> ensure_system(prompt)
      |> then(&chat.(%{state | messages: &1}))
    end
  end

  defp reflect_node(llm_opts, reflect_opts) do
    prompt = Keyword.get(reflect_opts, :reflect_prompt, @default_reflect_prompt)

    fn state ->
      [Message.system(prompt) | state.messages]
      |> ChatModel.structured(Keyword.put(llm_opts, :schema, @critique_schema))
      |> verdict(state)
    end
  end

  defp verdict({:ok, %{"approved" => true}}, state),
    do: %{reflect_approved: true, reflect_iteration: state.reflect_iteration + 1}

  defp verdict({:ok, %{"approved" => false} = critique}, state) do
    feedback = Map.get(critique, "feedback", "Revise the answer.")

    %{
      reflect_approved: false,
      reflect_iteration: state.reflect_iteration + 1,
      reflect_feedback: feedback,
      messages: [Message.human("[Reviewer feedback]\n\n#{feedback}")]
    }
  end

  defp verdict({:error, _reason}, state),
    do: %{reflect_approved: true, reflect_iteration: state.reflect_iteration + 1}

  defp route(%{reflect_approved: true}, _max), do: :done
  defp route(%{reflect_iteration: iteration}, max) when iteration >= max, do: :done
  defp route(_state, _max), do: :revise

  defp ensure_system(messages, nil), do: messages
  defp ensure_system([%Message.System{} | _] = messages, _prompt), do: messages
  defp ensure_system(messages, prompt), do: [Message.system(prompt) | messages]
end
