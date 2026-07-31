if Code.ensure_loaded?(Ecto) do
  defmodule LangEx.Migration.V4 do
    @moduledoc false
    use Ecto.Migration

    @table :lang_ex_checkpoints
    @writes_table :lang_ex_checkpoint_writes

    def up(opts \\ []) do
      prefix = Keyword.get(opts, :prefix, "public")

      alter table(@table, prefix: prefix) do
        add_if_not_exists(:checkpoint_ns, :text, null: false, default: "")
        add_if_not_exists(:source, :text, null: false, default: "step")
      end

      # A checkpoint is unique per (thread, namespace, id) now that
      # subgraphs share their parent's thread instead of mangling its ID.
      create_if_not_exists(
        unique_index(@table, [:thread_id, :checkpoint_ns, :checkpoint_id], prefix: prefix)
      )

      create_if_not_exists(
        index(@table, [:thread_id, :checkpoint_ns, :created_at],
          prefix: prefix,
          comment: "Latest-checkpoint lookup and history pagination within a namespace"
        )
      )

      drop_if_exists(unique_index(@table, [:thread_id, :checkpoint_id], prefix: prefix))
      drop_if_exists(index(@table, [:thread_id, :created_at], prefix: prefix))

      create_if_not_exists table(@writes_table, primary_key: false, prefix: prefix) do
        add(:thread_id, :text, null: false)
        add(:checkpoint_ns, :text, null: false, default: "")
        add(:anchor, :text, null: false)
        add(:task_id, :text, null: false)
        add(:idx, :integer, null: false, default: 0)
        add(:node, :text, null: false)
        add(:update, :jsonb, null: false)
        add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      end

      create_if_not_exists(
        unique_index(@writes_table, [:thread_id, :checkpoint_ns, :anchor, :task_id, :idx],
          prefix: prefix
        )
      )
    end

    def down(opts \\ []) do
      prefix = Keyword.get(opts, :prefix, "public")

      drop_if_exists(
        unique_index(@writes_table, [:thread_id, :checkpoint_ns, :anchor, :task_id, :idx],
          prefix: prefix
        )
      )

      drop_if_exists(table(@writes_table, prefix: prefix))

      create_if_not_exists(unique_index(@table, [:thread_id, :checkpoint_id], prefix: prefix))
      create_if_not_exists(index(@table, [:thread_id, :created_at], prefix: prefix))

      drop_if_exists(index(@table, [:thread_id, :checkpoint_ns, :created_at], prefix: prefix))

      drop_if_exists(
        unique_index(@table, [:thread_id, :checkpoint_ns, :checkpoint_id], prefix: prefix)
      )

      alter table(@table, prefix: prefix) do
        remove_if_exists(:checkpoint_ns, :text)
        remove_if_exists(:source, :text)
      end
    end
  end
end
