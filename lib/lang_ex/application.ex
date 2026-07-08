defmodule LangEx.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    :ok = LangEx.Checkpointer.Memory.create_table()
    :ok = LangEx.Graph.NodeCache.create_table()
    :ok = LangEx.Store.ETS.create_table()

    children =
      [
        {Task.Supervisor, name: LangEx.TaskSupervisor}
      ] ++ redix_child()

    Supervisor.start_link(children, strategy: :one_for_one, name: LangEx.Supervisor)
  end

  defp redix_child do
    Code.ensure_loaded?(Redix)
    |> redix_child_spec()
  end

  defp redix_child_spec(true) do
    redis_url = Application.get_env(:lang_ex, :redis_url, "redis://localhost:6379")
    [Redix.child_spec({redis_url, name: LangEx.Redix})]
  end

  defp redix_child_spec(false), do: []
end
