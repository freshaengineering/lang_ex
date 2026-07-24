if Code.ensure_loaded?(Ecto) do
  defmodule LangEx.Migration.V3 do
    @moduledoc false
    use Ecto.Migration

    @blobs_table :lang_ex_checkpoint_blobs

    def up(opts \\ []) do
      prefix = Keyword.get(opts, :prefix, "public")

      create_if_not_exists table(@blobs_table, primary_key: false, prefix: prefix) do
        add(:thread_id, :text, null: false)
        add(:hash, :text, null: false)
        add(:value, :jsonb, null: false)
        add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      end

      create_if_not_exists(unique_index(@blobs_table, [:thread_id, :hash], prefix: prefix))
    end

    def down(opts \\ []) do
      prefix = Keyword.get(opts, :prefix, "public")

      drop_if_exists(unique_index(@blobs_table, [:thread_id, :hash], prefix: prefix))
      drop_if_exists(table(@blobs_table, prefix: prefix))
    end
  end
end
