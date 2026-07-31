defmodule IncidentResponder do
  @moduledoc """
  DevOps Incident Response Assistant powered by LangEx.

  A conversational agent that triages alerts, runs diagnostics via tools,
  and takes remediation actions (restart, page on-call, update status page).

  ## Usage

      # Start a new session
      {:ok, session_id, greeting} = IncidentResponder.start_session()

      # Send messages
      {:ok, response} = IncidentResponder.chat(session_id, "api-gateway is returning 503s")
      {:ok, response} = IncidentResponder.chat(session_id, "yes, restart it")

      # Interactive REPL
      IncidentResponder.repl()
  """

  alias IncidentResponder.Graph
  alias LangEx.Command

  @checkpointer LangEx.Checkpointer.Postgres
  @repo IncidentResponder.Repo
  @recursion_limit 100

  @doc """
  Starts a new incident response session.
  Returns `{:ok, session_id, greeting}`.
  """
  def start_session(opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "inc-#{System.unique_integer([:positive])}")
    checkpointer = Keyword.get(opts, :checkpointer, @checkpointer)
    graph = Graph.build(checkpointer: checkpointer)
    config = build_config(session_id, opts)

    case LangEx.invoke(graph, %{messages: []}, config: config, recursion_limit: @recursion_limit) do
      {:interrupt, %{response: greeting}, _state} ->
        {:ok, session_id, greeting}

      {:ok, result} ->
        {:ok, session_id, result.last_response || "Ops here. What's the situation?"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sends a message in an existing session.
  Returns `{:ok, response}` or `{:done, response}` when the conversation ends.
  """
  def chat(session_id, message, opts \\ []) do
    checkpointer = Keyword.get(opts, :checkpointer, @checkpointer)
    graph = Graph.build(checkpointer: checkpointer)
    config = build_config(session_id, opts)

    case LangEx.invoke(graph, %Command{resume: message},
           config: config,
           recursion_limit: @recursion_limit
         ) do
      {:interrupt, %{response: response}, _state} ->
        {:ok, response}

      {:ok, result} ->
        {:done, result.last_response || "Incident resolved. Stay safe out there."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Copies a session onto a new ID, leaving the original untouched.

  Useful before a risky remediation: branch the incident, let the agent
  explore "restart the database instead" on the copy, and keep the real
  session resumable from where it was.
  """
  def branch_session(session_id, branch_id, opts \\ []) do
    graph()
    |> LangEx.copy_thread(branch_id, config: build_config(session_id, opts))
    |> tag(branch_id)
  end

  @doc """
  Returns the points where a human changed a session's state, newest
  first — the audit trail for "who edited this incident, and when".
  """
  def edit_history(session_id, opts \\ []) do
    LangEx.get_state_history(graph(),
      config: build_config(session_id, opts),
      source: [:update, :fork],
      limit: Keyword.get(opts, :limit, 20)
    )
  end

  @doc """
  Deletes a session's checkpoints, including any subgraph namespaces
  under it. Call when an incident is closed for good, or to satisfy a
  data-removal request.
  """
  def close_session(session_id, opts \\ []) do
    LangEx.delete_thread(graph(), config: build_config(session_id, opts))
  end

  @doc """
  Enforces the checkpoint retention window across all sessions.

  Run from a scheduled job. `:keep_latest` retains that many checkpoints
  per session regardless of age, so trimming history never leaves a live
  incident unresumable.
  """
  def enforce_retention(opts \\ []) do
    days = Keyword.get(opts, :days, 30)

    LangEx.Checkpointer.Postgres.prune(
      [repo: Keyword.get(opts, :repo, @repo)],
      older_than: DateTime.add(DateTime.utc_now(), -days, :day),
      keep_latest: Keyword.get(opts, :keep_latest, 5)
    )
  end

  @doc """
  Starts an interactive REPL. Type "quit" or "exit" to stop.
  """
  def repl(opts \\ []) do
    IO.puts("\n=== Acme Platform - Incident Response ===\n")

    case start_session(opts) do
      {:ok, session_id, greeting} ->
        IO.puts("Ops: #{greeting}\n")
        repl_loop(session_id, opts)

      {:error, reason} ->
        IO.puts("Failed to start session: #{inspect(reason)}")
    end
  end

  defp repl_loop(session_id, opts) do
    IO.gets("You: ")
    |> handle_repl_input(session_id, opts)
  end

  defp handle_repl_input(:eof, _session_id, _opts),
    do: IO.puts("\nSession ended.")

  defp handle_repl_input(input, session_id, opts) do
    input
    |> String.trim()
    |> process_repl_message(session_id, opts)
  end

  defp process_repl_message(message, _session_id, _opts)
       when message in ["quit", "exit", "q"],
       do: IO.puts("\nSession ended.")

  defp process_repl_message("", session_id, opts),
    do: repl_loop(session_id, opts)

  defp process_repl_message(message, session_id, opts) do
    message
    |> then(&chat(session_id, &1, opts))
    |> handle_chat_response(session_id, opts)
  end

  defp handle_chat_response({:ok, response}, session_id, opts) do
    IO.puts("\nOps: #{response}\n")
    repl_loop(session_id, opts)
  end

  defp handle_chat_response({:done, response}, _session_id, _opts) do
    IO.puts("\nOps: #{response}\n")
    IO.puts("[Incident closed]")
  end

  defp handle_chat_response({:error, reason}, session_id, opts) do
    IO.puts("\n[Error: #{inspect(reason)}]\n")
    repl_loop(session_id, opts)
  end

  defp build_config(session_id, opts) do
    [thread_id: session_id, repo: Keyword.get(opts, :repo, @repo)]
  end

  # Thread operations only need the compiled graph's checkpointer, not its
  # nodes, so they can share one build.
  defp graph, do: Graph.build(checkpointer: @checkpointer)

  defp tag(:ok, branch_id), do: {:ok, branch_id}
  defp tag({:error, reason}, _branch_id), do: {:error, reason}
end
