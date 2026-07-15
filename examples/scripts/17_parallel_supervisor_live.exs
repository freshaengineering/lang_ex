# Parallel supervisor fan-out, powered by a real model.
#
# A research lead delegates to two specialists AT ONCE (`parallel: true`):
# a `flights` agent and a `hotels` agent, each with its own tool. The two
# workers run concurrently and their attributed results are fanned back to
# the lead, which synthesizes a final plan. Each worker's task is carried
# in its handoff arguments, so the workers never see one another's briefs.
#
# Requires an API key:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   elixir examples/scripts/17_parallel_supervisor_live.exs

Mix.install([{:lang_ex, path: Path.expand("../..", __DIR__)}])

defmodule ParallelLive do
  alias LangEx.Message
  alias LangEx.Prebuilt.Supervisor
  alias LangEx.Tool

  @model "claude-haiku-4-5"

  @request "Plan a weekend trip to Lisbon from London, this Friday to Sunday, for 2 people. " <>
             "Book flights and a hotel."

  def run do
    IO.puts("=== Traveler ===\n#{@request}\n")

    state =
      build()
      |> LangEx.stream(%{messages: [Message.human(@request)]})
      |> Enum.reduce(nil, &trace/2)

    IO.puts("\n=== Lead's plan ===\n#{List.last(state.messages).content}")
    IO.puts("\ntoken usage: #{inspect(state.llm_usage)}")
  end

  defp trace({:node_start, node}, acc) do
    IO.puts("  ...#{node} working")
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
      parallel: true,
      model: @model,
      max_tokens: 512,
      prompt:
        "You are a travel planning lead. In your FIRST turn, delegate to BOTH the " <>
          "flights agent and the hotels agent in a single turn (two tool calls at once). " <>
          "Do not ask the traveler for more details — assume reasonable defaults. Once " <>
          "both report back, combine their findings into a short plan.",
      agents: [
        [
          name: :flights,
          model: @model,
          max_tokens: 512,
          system_prompt: "You find flights. Use search_flights and report the best option.",
          tools: [flights_tool()]
        ],
        [
          name: :hotels,
          model: @model,
          max_tokens: 512,
          system_prompt: "You find hotels. Use search_hotels and report the best option.",
          tools: [hotels_tool()]
        ]
      ]
    )
  end

  defp flights_tool do
    %Tool{
      name: "search_flights",
      description: "Search flights to a city.",
      parameters: %{
        type: "object",
        properties: %{city: %{type: "string"}},
        required: ["city"]
      },
      function: fn %{"city" => city} ->
        %{city: city, airline: "TAP", price_usd: 240, depart: "Fri 18:00", return: "Sun 21:00"}
      end
    }
  end

  defp hotels_tool do
    %Tool{
      name: "search_hotels",
      description: "Search hotels in a city.",
      parameters: %{
        type: "object",
        properties: %{city: %{type: "string"}},
        required: ["city"]
      },
      function: fn %{"city" => city} ->
        %{city: city, hotel: "Baixa Boutique", price_per_night_usd: 120, rating: 4.6}
      end
    }
  end
end

ParallelLive.run()
