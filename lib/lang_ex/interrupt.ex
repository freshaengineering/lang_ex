defmodule LangEx.Interrupt do
  @moduledoc """
  Pause graph execution and wait for external input.

  Call `interrupt/1` inside any node function. Each call site gets a
  stable ID derived from the node name and the call order within the
  node (`"node:0"`, `"node:1"`, ...). If a resume value has been
  provided for that ID, it is returned immediately. Otherwise execution
  pauses and the payload is surfaced to the caller.

  A node may interrupt multiple times: on each resume the node re-runs
  from the top, earlier `interrupt/1` calls return their recorded
  values, and the first unanswered call pauses again.
  """

  @doc """
  Pauses graph execution with the given payload.

  Returns the resume value when the graph is resumed via
  `LangEx.invoke(graph, %Command{resume: value}, config: ...)`.
  Resume with a single value to answer the first pending interrupt, or
  with a map of `%{interrupt_id => value}` to answer several at once.
  """
  @spec interrupt(term()) :: term()
  def interrupt(payload \\ nil) do
    id = next_interrupt_id()

    :lang_ex_resume_values
    |> Process.get(%{})
    |> Map.fetch(id)
    |> resolve_resume(id, payload)
  end

  defp resolve_resume({:ok, value}, _id, _payload), do: value
  defp resolve_resume(:error, id, payload), do: throw({:lang_ex_interrupt, id, payload})

  defp next_interrupt_id do
    node = Process.get(:lang_ex_current_node)
    index = Process.get(:lang_ex_interrupt_counter, 0)
    Process.put(:lang_ex_interrupt_counter, index + 1)
    "#{node}:#{index}"
  end
end
