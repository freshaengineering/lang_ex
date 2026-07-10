if Code.ensure_loaded?(Ecto) do
  defmodule LangEx.IntegrationRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :lang_ex, adapter: Ecto.Adapters.Postgres
  end

  defmodule LangEx.IntegrationRepo.Migrations.AddLangEx do
    @moduledoc false
    use Ecto.Migration

    def up, do: LangEx.Migration.up()
    def down, do: LangEx.Migration.down()
  end

  defmodule LangEx.Integration do
    @moduledoc false
    # Helpers for integration tests (`mix test --include integration`).
    # Service endpoints come from LANG_EX_POSTGRES_URL / LANG_EX_REDIS_URL,
    # defaulting to the docker-compose.yml services.

    @migration_version 20_240_101_000_000

    def postgres_url do
      System.get_env(
        "LANG_EX_POSTGRES_URL",
        "ecto://lang_ex:lang_ex@localhost:5432/lang_ex_dev"
      )
    end

    def redis_url, do: System.get_env("LANG_EX_REDIS_URL", "redis://localhost:6379")

    def start_repo! do
      [url: postgres_url(), pool_size: 2, log: false]
      |> LangEx.IntegrationRepo.start_link()
      |> handle_start()
    end

    def migrate! do
      Ecto.Migrator.up(
        LangEx.IntegrationRepo,
        @migration_version,
        LangEx.IntegrationRepo.Migrations.AddLangEx,
        log: false
      )

      :ok
    end

    def rollback! do
      Ecto.Migrator.down(
        LangEx.IntegrationRepo,
        @migration_version,
        LangEx.IntegrationRepo.Migrations.AddLangEx,
        log: false
      )

      :ok
    end

    defp handle_start({:ok, _pid}), do: :ok
    defp handle_start({:error, {:already_started, _pid}}), do: :ok
  end
end
