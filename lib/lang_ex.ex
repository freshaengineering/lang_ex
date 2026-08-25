defmodule LangEx do
  @moduledoc """
  Stateful LLM agents for Elixir.

  `invoke/3` and `stream/3` run a compiled graph. Build one with
  `LangEx.Prebuilt.agent/1`, or with `LangEx.Graph` when the workflow
  has a shape of its own.

      alias LangEx.Message
      alias LangEx.Tool

      lookup = %Tool{
        name: "lookup_service",
        description: "Health and error rate for a service.",
        parameters: %{
          type: "object",
          properties: %{name: %{type: "string"}},
          required: ["name"]
        },
        function: fn %{"name" => name} -> %{name: name, status: :degraded} end
      }

      agent =
        LangEx.Prebuilt.agent(
          model: "claude-sonnet-4-20250514",
          system_prompt: "You are on-call. Diagnose, then recommend.",
          tools: [lookup]
        )

      {:ok, result} =
        LangEx.invoke(agent, %{messages: [Message.human("api-gateway 5xxs spiked")]})

  See the [README](readme.html) for a tour — graphs, interrupts,
  checkpointing, teams, and streaming.
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

  @doc "Deletes every checkpoint for the thread in the config, subgraphs included."
  @spec delete_thread(Compiled.t(), keyword()) :: :ok | {:error, term()}
  defdelegate delete_thread(graph, opts), to: Compiled

  @doc "Copies a thread's full history onto a new thread, branching it safely."
  @spec copy_thread(Compiled.t(), String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate copy_thread(graph, target_thread_id, opts), to: Compiled
end
