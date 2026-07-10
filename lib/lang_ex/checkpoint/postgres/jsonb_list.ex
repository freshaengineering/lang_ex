if Code.ensure_loaded?(Ecto) do
  defmodule LangEx.Checkpointer.Postgres.JsonbList do
    @moduledoc false
    # A JSON array stored in a single jsonb column. Ecto's built-in
    # {:array, _} types map to Postgres array columns (jsonb[]), which
    # does not match the jsonb columns created by LangEx.Migration.
    use Ecto.Type

    @impl true
    def type, do: :map

    @impl true
    def cast(list) when is_list(list), do: {:ok, list}
    def cast(nil), do: {:ok, nil}
    def cast(_other), do: :error

    @impl true
    def dump(list) when is_list(list), do: {:ok, list}
    def dump(nil), do: {:ok, nil}
    def dump(_other), do: :error

    @impl true
    def load(list) when is_list(list), do: {:ok, list}
    def load(nil), do: {:ok, nil}
    def load(_other), do: :error
  end
end
