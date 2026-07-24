if Code.ensure_loaded?(Ecto) do
  defmodule LangEx.Checkpointer.Postgres.BlobSchema do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "lang_ex_checkpoint_blobs" do
      field(:thread_id, :string)
      field(:hash, :string)
      field(:value, :map)
      field(:inserted_at, :utc_datetime_usec)
    end
  end
end
