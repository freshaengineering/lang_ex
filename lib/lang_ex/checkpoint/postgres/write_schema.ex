if Code.ensure_loaded?(Ecto) do
  defmodule LangEx.Checkpointer.Postgres.WriteSchema do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "lang_ex_checkpoint_writes" do
      field(:thread_id, :string)
      field(:checkpoint_ns, :string, default: "")
      field(:anchor, :string)
      field(:task_id, :string)
      field(:idx, :integer, default: 0)
      field(:node, :string)
      field(:update, :map)
      field(:inserted_at, :utc_datetime_usec)
    end
  end
end
