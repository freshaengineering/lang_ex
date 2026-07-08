if Code.ensure_loaded?(Ecto) do
  defmodule LangEx.Store.Postgres.Schema do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "lang_ex_store" do
      field(:namespace, {:array, :string})
      field(:key, :string)
      field(:value, :map)
      field(:inserted_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end
end
