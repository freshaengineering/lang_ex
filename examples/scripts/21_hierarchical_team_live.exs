# Hierarchical teams: a team nested as a worker of another team — live.
#
# A top-level "editor-in-chief" supervisor delegates to a `research_team`,
# which is ITSELF a supervisor coordinating two specialists (a facts agent
# and a numbers agent). The nested team runs as a worker, reports its
# combined findings up, and the top supervisor writes the final brief.
#
#   editor (supervisor)
#     └─ research_team (supervisor)
#          ├─ facts   (tool: get_facts)
#          └─ numbers (tool: get_numbers)
#
# Requires an API key:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   elixir examples/scripts/21_hierarchical_team_live.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule HierarchyLive do
  alias LangEx.Message
  alias LangEx.Prebuilt.Supervisor
  alias LangEx.Tool

  @model "claude-haiku-4-5"

  @request "Write a two-line brief on electric vehicle adoption: one fact and one number."

  def run do
    IO.puts("=== Request ===\n#{@request}\n")

    state =
      build()
      |> LangEx.stream(%{messages: [Message.human(@request)]})
      |> Enum.reduce(nil, &trace/2)

    IO.puts("\n=== Editor's brief ===\n#{List.last(state.messages).content}")
    IO.puts("\ntoken usage: #{inspect(Map.take(state.llm_usage, [:input_tokens, :output_tokens]))}")
  end

  defp trace({:node_start, node}, acc) do
    IO.puts("  ...#{node}")
    acc
  end

  defp trace({:done, {:ok, state}}, _acc), do: state

  defp trace({:done, {:error, reason}}, acc) do
    IO.inspect(reason, label: "error")
    acc
  end

  defp trace(_event, acc), do: acc

  defp build do
    Supervisor.create(
      model: @model,
      max_tokens: 400,
      supervisor_name: :editor,
      prompt:
        "You are the editor-in-chief. Delegate all research to the research_team, then " <>
          "write a two-line brief combining the fact and the number they return.",
      agents: [{:research_team, research_team()}]
    )
  end

  defp research_team do
    Supervisor.create(
      model: @model,
      max_tokens: 400,
      supervisor_name: :research_lead,
      prompt:
        "You are the research lead. Get one fact from the facts agent and one number " <>
          "from the numbers agent, then report both back concisely.",
      agents: [
        [
          name: :facts,
          model: @model,
          max_tokens: 200,
          system_prompt: "You provide one concise fact. Use get_facts.",
          tools: [facts_tool()]
        ],
        [
          name: :numbers,
          model: @model,
          max_tokens: 200,
          system_prompt: "You provide one concise statistic. Use get_numbers.",
          tools: [numbers_tool()]
        ]
      ]
    )
  end

  defp facts_tool do
    %Tool{
      name: "get_facts",
      description: "Get a fact about a topic.",
      parameters: %{type: "object", properties: %{topic: %{type: "string"}}, required: ["topic"]},
      function: fn %{"topic" => topic} ->
        %{topic: topic, fact: "EVs have far fewer moving parts than combustion cars."}
      end
    }
  end

  defp numbers_tool do
    %Tool{
      name: "get_numbers",
      description: "Get a statistic about a topic.",
      parameters: %{type: "object", properties: %{topic: %{type: "string"}}, required: ["topic"]},
      function: fn %{"topic" => topic} ->
        %{topic: topic, stat: "Global EV sales share reached about 18% in 2024."}
      end
    }
  end
end

HierarchyLive.run()
