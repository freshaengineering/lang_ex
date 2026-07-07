defmodule LangEx.Migration do
  @moduledoc """
  Migrations create and modify the database tables LangEx needs to function.

  ## Usage

  Generate an Ecto migration that wraps calls to `LangEx.Migration`:

      mix ecto.gen.migration add_lang_ex

  Then in the generated migration:

      defmodule MyApp.Repo.Migrations.AddLangEx do
        use Ecto.Migration

        def up, do: LangEx.Migration.up()
        def down, do: LangEx.Migration.down()
      end

  Run `mix ecto.migrate` to create the tables.

  ## Versioned Upgrades

  Migrations between versions are idempotent. When upgrading LangEx,
  generate a new migration and specify the version:

      defmodule MyApp.Repo.Migrations.UpgradeLangExToV2 do
        use Ecto.Migration

        def up, do: LangEx.Migration.up(version: 2)
        def down, do: LangEx.Migration.down(version: 2)
      end

  ## Schema Isolation (Prefixes)

  Supports PostgreSQL schema namespacing via the `prefix` option:

      def up, do: LangEx.Migration.up(prefix: "private")
      def down, do: LangEx.Migration.down(prefix: "private")
  """

  @current_version 2

  @migrations %{
    1 => LangEx.Migration.V1,
    2 => LangEx.Migration.V2
  }

  @doc """
  Runs all migrations up to the specified version (default: latest).

  ## Options

  - `:version` - target migration version (default: #{@current_version})
  - `:prefix` - PostgreSQL schema prefix (default: `"public"`)
  """
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    version = Keyword.get(opts, :version, @current_version)
    prefix = Keyword.get(opts, :prefix, "public")

    1..version
    |> Enum.each(fn v ->
      migration = Map.fetch!(@migrations, v)
      migration.up(prefix: prefix)
    end)

    :ok
  end

  @doc """
  Rolls back migrations down to the specified version (default: removes all).

  ## Options

  - `:version` - target version to roll back to (default: 0, removes everything)
  - `:prefix` - PostgreSQL schema prefix (default: `"public"`)
  """
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    version = Keyword.get(opts, :version, 0)
    prefix = Keyword.get(opts, :prefix, "public")
    current = Keyword.get(opts, :from, @current_version)

    current..max(version + 1, 1)
    |> Enum.each(fn v ->
      migration = Map.fetch!(@migrations, v)
      migration.down(prefix: prefix)
    end)

    :ok
  end

  @doc "Returns the latest migration version."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version
end
