if Code.ensure_loaded?(Ecto) do
  defmodule LangEx.Checkpointer.Postgres.Schema do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "lang_ex_checkpoints" do
      field(:thread_id, :string)
      field(:checkpoint_id, :string)
      field(:parent_id, :string)
      field(:state, :map)
      field(:next_nodes, {:array, :string})
      field(:step, :integer, default: 0)
      field(:metadata, :map, default: %{})
      field(:pending_interrupts, {:array, :map})
      field(:created_at, :utc_datetime_usec)
      field(:version, :integer, default: 1)
    end
  end
end
