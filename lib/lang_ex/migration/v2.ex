if Code.ensure_loaded?(Ecto) do
  defmodule LangEx.Migration.V2 do
    @moduledoc false
    use Ecto.Migration

    @store_table :lang_ex_store
    @checkpoints_table :lang_ex_checkpoints

    def up(opts \\ []) do
      prefix = Keyword.get(opts, :prefix, "public")

      create_if_not_exists table(@store_table, primary_key: false, prefix: prefix) do
        add(:namespace, {:array, :text}, null: false)
        add(:key, :text, null: false)
        add(:value, :jsonb, null: false)
        add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
        add(:updated_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      end

      create_if_not_exists(unique_index(@store_table, [:namespace, :key], prefix: prefix))

      alter table(@checkpoints_table, prefix: prefix) do
        add_if_not_exists(:version, :integer, null: false, default: 1)
      end
    end

    def down(opts \\ []) do
      prefix = Keyword.get(opts, :prefix, "public")

      alter table(@checkpoints_table, prefix: prefix) do
        remove_if_exists(:version)
      end

      drop_if_exists(unique_index(@store_table, [:namespace, :key], prefix: prefix))
      drop_if_exists(table(@store_table, prefix: prefix))
    end
  end
end
