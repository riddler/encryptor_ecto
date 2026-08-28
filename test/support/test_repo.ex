defmodule Encryptor.Ecto.TestRepo do
  @moduledoc """
  The repository the `:database`-tagged tests run against.

  It exists because an `Ecto.Type` that has only ever been exercised through a
  hand-called `dump/3` has not been shown to work. The adapter is what decides
  when the callbacks run, what it hands them, and what it does with a `:binary`
  they return, and a mock repository reproduces none of that. The properties
  this repository is here to prove are the ones only a real column can show: a
  ciphertext survives a round trip through a `bytea` column byte for byte, a
  `nil` stays `NULL` rather than becoming encrypted bytes, and a value written
  in one tenant's scope does not read back in another's.

  It is test-only in every sense. `ecto_sql` and `postgrex` are `only: :test`
  dependencies, this module lives under `test/support` and so compiles only in
  the test environment, and nothing in `lib/` names it. The library's own
  dependency claim - Ecto and the vault, and nothing else - is unchanged.

  Configuration comes from the standard `PG*` environment variables, which is
  the same place `Encryptor.Ecto.TestDatabase`'s reachability probe reads and
  the same place CI sets. One endpoint, described once.
  """

  use Ecto.Repo,
    otp_app: :encryptor_ecto,
    adapter: Ecto.Adapters.Postgres

  alias Ecto.Adapters.Postgres
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator

  @migrations [
    {0, Encryptor.Ecto.TestMigration},
    {1, Encryptor.Ecto.TestMigrationTextAndMap},
    {2, Encryptor.Ecto.TestMigrationSignups},
    {3, Encryptor.Ecto.TestMigrationMigrator}
  ]

  @doc """
  Creates the database if it is absent, starts the repository, migrates it,
  and puts the sandbox in manual mode.

  Called from `test/test_helper.exs`, and only on the arm where the probe
  found a server listening. Everything it does is idempotent: `storage_up/1`
  reports an existing database rather than failing, and the migrator skips a
  version already in `schema_migrations`, so a developer running the suite
  twice against the same container gets the same result as the first run and
  as CI's fresh one.
  """
  @spec setup!() :: :ok
  def setup! do
    config = Application.fetch_env!(:encryptor_ecto, __MODULE__)

    _existing_or_created = Postgres.storage_up(config)
    {:ok, _pid} = start_link(config)

    Migrator.run(__MODULE__, @migrations, :up, all: true, log: false)
    Sandbox.mode(__MODULE__, :manual)

    :ok
  end
end
