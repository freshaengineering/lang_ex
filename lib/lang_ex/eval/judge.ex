defmodule LangEx.Eval.Judge do
  @moduledoc """
  LLM-as-judge scoring of agent tool-use trajectories.

  Renders either a message history (compact transcript) or an extracted
  trajectory (see `LangEx.Eval.Trajectory`) and asks a judge model to
  score it between 0.0 and 1.0 against the supplied criteria, using
  structured output for a machine-readable verdict.
  """

  alias LangEx.Eval.Trajectory
  alias LangEx.LLM.Anthropic
  alias LangEx.LLM.ChatModel
  alias LangEx.Message

  @ai_content_limit 500
  @tool_content_limit 200

  @schema %{
    type: "object",
    properties: %{
      score: %{
        type: "number",
        minimum: 0,
        maximum: 1,
        description: "Trajectory quality from 0.0 (very poor) to 1.0 (excellent)."
      },
      reasoning: %{type: "string", description: "Short justification for the score."}
    },
    required: ["score", "reasoning"]
  }

  @system_prompt """
  You are an expert evaluator of agent tool-use trajectories. Judge the
  trajectory on efficiency (no redundant or unnecessary tool calls),
  progression (each call builds on the results of prior calls), and how
  well it covers the stated criteria. Respond by calling the `respond`
  tool with a `score` between 0 and 1 and a short `reasoning`.
  """

  @default_criteria "The agent accomplishes the task with the fewest effective tool calls."

  @doc """
  Score a trajectory with an LLM judge.

  Accepts either a full message history (rendered as a compact
  transcript of AI turns, tool calls, and tool replies) or a list of
  trajectory steps (rendered as one `name(args)` line per call).

  ## Options

  - `:model` (required) - judge model string
  - `:provider` - LLM provider module (default `LangEx.LLM.Anthropic`)
  - `:criteria` - description of what a good trajectory looks like,
    spliced into the judge prompt
  - `:llm_opts` - extra options forwarded to the provider call
  """
  @spec run([Message.t()] | [Trajectory.step()], keyword()) ::
          {:ok, %{score: float(), reasoning: String.t()}} | {:error, term()}
  def run(messages_or_trajectory, opts) do
    [
      Message.system(@system_prompt),
      Message.human(judge_prompt(messages_or_trajectory, opts))
    ]
    |> ChatModel.structured(structured_opts(opts))
    |> normalize_verdict()
  end

  defp judge_prompt(messages_or_trajectory, opts) do
    """
    Evaluate the following agent trajectory.

    ## Criteria for a good trajectory

    #{Keyword.get(opts, :criteria, @default_criteria)}

    ## Trajectory

    #{render(messages_or_trajectory)}

    Score the trajectory from 0.0 to 1.0 and explain your reasoning.
    """
  end

  defp structured_opts(opts) do
    opts
    |> Keyword.get(:llm_opts, [])
    |> Keyword.merge(
      schema: @schema,
      provider: Keyword.get(opts, :provider, Anthropic),
      model: Keyword.fetch!(opts, :model)
    )
  end

  defp render([]), do: "(empty trajectory)"
  defp render([%_{} | _] = messages), do: render_messages(messages)
  defp render(steps), do: render_steps(steps)

  defp render_messages(messages) do
    messages
    |> Enum.flat_map(&transcript_lines/1)
    |> Enum.join("\n")
  end

  defp render_steps(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.map_join("\n", &step_line/1)
  end

  defp step_line({step, index}), do: "#{index}. #{step.name}(#{Jason.encode!(step.args)})"

  defp transcript_lines(%Message.AI{content: content, tool_calls: calls}),
    do: ai_lines(content) ++ Enum.map(calls, &tool_call_line/1)

  defp transcript_lines(%Message.Tool{content: content}),
    do: ["Tool result: " <> trim(content, @tool_content_limit)]

  defp transcript_lines(%Message.Human{content: content}),
    do: ["Human: " <> trim(content, @ai_content_limit)]

  defp transcript_lines(_message), do: []

  defp ai_lines(nil), do: []
  defp ai_lines(content), do: ["AI: " <> trim(content, @ai_content_limit)]

  defp tool_call_line(call), do: "  -> tool call #{call.name}(#{Jason.encode!(call.args)})"

  defp trim(content, limit) when byte_size(content) <= limit, do: content
  defp trim(content, limit), do: String.slice(content, 0, limit) <> "…"

  defp normalize_verdict({:ok, %{"score" => score, "reasoning" => reasoning}})
       when is_number(score) and is_binary(reasoning),
       do: {:ok, %{score: score / 1, reasoning: reasoning}}

  defp normalize_verdict({:ok, _data}), do: {:error, :invalid_judge_output}
  defp normalize_verdict({:error, _reason} = error), do: error
end
