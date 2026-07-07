defmodule LangEx.Telemetry.Runs do
  @moduledoc """
  Run-tree correlation for telemetry spans.

  Wraps `:telemetry.span/3` so that every span carries a `:run_id` and a
  `:parent_run_id` in its metadata. Nested spans (graph invoke → step →
  node → LLM call / checkpoint) form a tree that can be reconstructed
  from the emitted events, which is the foundation for tracing UIs and
  the OpenTelemetry bridge.

  The current run id lives in the process dictionary. Node tasks run in
  separate processes, so the executor captures the parent's run id
  before spawning and seeds it with `inherit_run_id/1` inside the task.
  """

  @pdict_key :lang_ex_run_id

  @doc """
  Emits a `:telemetry.span/3` with `:run_id`/`:parent_run_id` correlation
  merged into both start and stop metadata.
  """
  @spec span([atom(), ...], map(), (-> {term(), map()})) :: term()
  def span(event, metadata, fun) do
    parent_id = Process.get(@pdict_key)
    run_id = generate_id()
    Process.put(@pdict_key, run_id)

    try do
      :telemetry.span(event, correlate(metadata, run_id, parent_id), fn ->
        {result, stop_metadata} = fun.()
        {result, correlate(stop_metadata, run_id, parent_id)}
      end)
    after
      restore_parent(parent_id)
    end
  end

  @doc "Returns the run id of the currently executing span, if any."
  @spec current_run_id() :: String.t() | nil
  def current_run_id, do: Process.get(@pdict_key)

  @doc "Adopts a run id captured in a parent process (for spawned tasks)."
  @spec inherit_run_id(String.t() | nil) :: :ok
  def inherit_run_id(nil), do: :ok

  def inherit_run_id(run_id) do
    Process.put(@pdict_key, run_id)
    :ok
  end

  defp correlate(metadata, run_id, parent_id),
    do: Map.merge(metadata, %{run_id: run_id, parent_run_id: parent_id})

  defp restore_parent(nil), do: Process.delete(@pdict_key)
  defp restore_parent(parent_id), do: Process.put(@pdict_key, parent_id)

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
