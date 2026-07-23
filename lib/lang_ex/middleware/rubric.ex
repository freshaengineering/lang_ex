defmodule LangEx.Middleware.Rubric do
  @moduledoc """
  Middleware that gates the agent's final answer against a rubric.

  When the agent is about to finish (its latest message makes no tool
  calls), a critic scores the answer against `:rubric` via
  `LangEx.LLM.ChatModel.structured/2`. If it falls short and attempts
  remain, the shortfall is appended as feedback and the agent is routed back
  for another pass — an exit gate on the tool loop, complementary to
  `LangEx.Prebuilt.Reflect` (which critiques every draft rather than only
  the final one).

  ## Options

  - `:rubric` (required) - the "done" criteria the answer must satisfy
  - `:model` / `:provider` - the critic model (required)
  - `:max_attempts` - how many times the gate may bounce an answer back
    (default `2`); once exhausted the answer is accepted
  - `:resilient` and other options are forwarded to the critic call
  """

  alias LangEx.LLM.ChatModel
  alias LangEx.Message
  alias LangEx.Middleware

  @default_max_attempts 2
  @middleware_opt_keys [:rubric, :max_attempts]

  @verdict_schema %{
    "type" => "object",
    "properties" => %{
      "passes" => %{
        "type" => "boolean",
        "description" => "true when the answer satisfies the rubric"
      },
      "feedback" => %{
        "type" => "string",
        "description" => "what is missing when it does not pass"
      }
    },
    "required" => ["passes"]
  }

  @doc "Builds a rubric completion-gate middleware. See the module doc for options."
  @spec new(keyword()) :: Middleware.t()
  def new(opts) do
    Middleware.new(
      name: :rubric,
      after_model: hook(opts),
      state_schema: [rubric_attempts: 0]
    )
  end

  defp hook(opts) do
    {mw_opts, llm_opts} = Keyword.split(opts, @middleware_opt_keys)
    rubric = Keyword.fetch!(mw_opts, :rubric)
    max_attempts = Keyword.get(mw_opts, :max_attempts, @default_max_attempts)

    fn state ->
      state.messages
      |> List.last()
      |> gate(state, rubric, max_attempts, llm_opts)
    end
  end

  defp gate(%Message.AI{tool_calls: [_ | _]}, _state, _rubric, _max, _llm_opts), do: %{}

  defp gate(%Message.AI{} = answer, state, rubric, max_attempts, llm_opts),
    do: evaluate(state.rubric_attempts >= max_attempts, answer, state, rubric, llm_opts)

  defp gate(_other, _state, _rubric, _max, _llm_opts), do: %{}

  defp evaluate(true, _answer, _state, _rubric, _llm_opts), do: %{}

  defp evaluate(false, answer, state, rubric, llm_opts) do
    [Message.system(judge_prompt(rubric)), Message.human(answer.content || "")]
    |> ChatModel.structured(Keyword.put(llm_opts, :schema, @verdict_schema))
    |> verdict(state)
  end

  defp verdict({:ok, %{"passes" => true}}, _state), do: %{}

  defp verdict({:ok, %{"passes" => false} = v}, state) do
    feedback = Map.get(v, "feedback", "Revise the answer to satisfy the rubric.")

    %{
      :messages => [Message.human("[Completion check failed]\n\n#{feedback}")],
      :rubric_attempts => state.rubric_attempts + 1,
      Middleware.jump_key() => :model
    }
  end

  defp verdict({:error, _reason}, _state), do: %{}

  defp judge_prompt(rubric) do
    "You are a strict reviewer. Decide whether the assistant's answer satisfies this rubric. " <>
      "Approve only when every requirement is met.\n\nRubric:\n#{rubric}"
  end
end
