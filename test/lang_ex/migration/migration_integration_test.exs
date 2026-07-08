defmodule LangEx.MigrationIntegrationTest do
  # Requires a running Postgres (docker-compose.yml) — run with:
  #   mix test --include integration
  use ExUnit.Case, async: false

  @moduletag :integration

  alias LangEx.Checkpoint
  alias LangEx.Checkpointer.Postgres
  alias LangEx.IntegrationRepo

  setup_all do
    :ok = LangEx.Integration.start_repo!()
    :ok
  end

  test "current_version covers every registered migration" do
    assert LangEx.Migration.current_version() == 2
  end

  test "down and up cycle leaves working tables" do
    :ok = LangEx.Integration.migrate!()
    :ok = LangEx.Integration.rollback!()

    refute table_exists?("lang_ex_checkpoints")
    refute table_exists?("lang_ex_store")

    :ok = LangEx.Integration.migrate!()

    assert table_exists?("lang_ex_checkpoints")
    assert table_exists?("lang_ex_store")

    thread = "migration-int-#{System.unique_integer([:positive])}"
    config = [repo: IntegrationRepo, thread_id: thread]

    :ok =
      Postgres.save(
        config,
        Checkpoint.new(
          thread_id: thread,
          state: %{v: 1},
          next_nodes: [:a],
          step: 0,
          metadata: %{}
        )
      )

    assert {:ok, %Checkpoint{state: %{v: 1}, version: 2}} = Postgres.load(config)
  end

  defp table_exists?(table) do
    %{rows: [[exists]]} =
      IntegrationRepo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = $1)",
        [table]
      )

    exists
  end
end
