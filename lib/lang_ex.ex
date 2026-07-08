defmodule LangEx do
  @moduledoc """
  LangEx — LangGraph for Elixir.

  A graph-based agent orchestration library inspired by LangGraph.
  Build stateful, multi-step LLM workflows using nodes, edges,
  conditional routing, and composable state reducers.

  ## Quick Start

      alias LangEx.Graph
      alias LangEx.Message

      graph =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(:greet, fn state ->
          name = hd(state.messages).content
          %{messages: [Message.ai("Hello, \#{name}!")]}
        end)
        |> Graph.add_edge(:__start__, :greet)
        |> Graph.add_edge(:greet, :__end__)
        |> Graph.compile()

      {:ok, result} = LangEx.invoke(graph, %{messages: [Message.human("World")]})
  """

  alias LangEx.Graph.Compiled

  @doc "Executes a compiled graph with the given input state."
  @spec invoke(Compiled.t(), map() | LangEx.Command.t(), keyword()) ::
          {:ok, map()} | {:interrupt, term(), map()} | {:error, term()}
  defdelegate invoke(graph, input, opts \\ []), to: Compiled

  @doc "Returns a lazy stream of execution events from the compiled graph."
  defdelegate stream(graph, input, opts \\ []), to: LangEx.Graph.Stream

  @doc "Returns the latest (or a specific) checkpoint for a thread."
  @spec get_state(Compiled.t(), keyword()) ::
          {:ok, LangEx.Checkpoint.t()} | :none | {:error, term()}
  defdelegate get_state(graph, opts), to: Compiled

  @doc "Returns the checkpoint history for a thread, most recent first."
  @spec get_state_history(Compiled.t(), keyword()) :: [LangEx.Checkpoint.t()]
  defdelegate get_state_history(graph, opts), to: Compiled

  @doc "Applies an update to checkpointed state, saving a new forked checkpoint."
  @spec update_state(Compiled.t(), map(), keyword()) ::
          {:ok, LangEx.Checkpoint.t()} | {:error, term()}
  defdelegate update_state(graph, update, opts), to: Compiled

  @doc "Deletes every checkpoint for the thread in the config."
  @spec delete_thread(Compiled.t(), keyword()) :: :ok | {:error, term()}
  defdelegate delete_thread(graph, opts), to: Compiled
end
