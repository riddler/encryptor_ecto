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
  under one scope does not read back in another's.

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
    {3, Encryptor.Ecto.TestMigrationMigrator},
    {4, Encryptor.Ecto.TestMigrationWrappedKeys},
    {5, Encryptor.Ecto.TestMigrationScalars},
    # The three steps of a 0.3.0 adopter's upgrade, in the order they happen:
    # the table as that version's generator wrote it, a row written into it
    # before the columns existed, and the additive migration ADR-0005 decision 6
    # fixes. Only a timeline like this can show that the backfill is right;
    # a row inserted from a test after the migration proves nothing about one
    # that was already there.
    {6, Encryptor.Ecto.TestMigrationWrappedKeys03},
    {7, Encryptor.Ecto.TestMigrationWrappedKeys03Row},
    {8, Encryptor.Ecto.TestMigrationWrappedKeysShape},
    # The same table again, in a schema the default search path does not
    # reach, so `Encryptor.Ecto.KeyStore`'s `:prefix` has something to route
    # to. It is a migration rather than test setup because a sandboxed test's
    # `CREATE SCHEMA` would roll back with the test.
    {9, Encryptor.Ecto.TestMigrationWrappedKeysPrefix},
    {10, Encryptor.Ecto.TestMigrationCardholders},
    # The migrate-from-cloak runbook's own host: one secret column and two
    # token columns under a single legacy key.
    {11, Encryptor.Ecto.TestMigrationRunbook},
    # The two-vaults guide's host: a customer-scoped table, an
    # agreement-scoped one, and the agreement vault's own key table.
    {12, Encryptor.Ecto.TestMigrationTwoVaults}
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

  One exception, and it is a one-time cost rather than a standing one.
  Migration 4 (`Encryptor.Ecto.TestMigrationWrappedKeys`) gained
  `wrapping_shape` and `key_id` *in place* rather than as a new migration, so
  a local `encryptor_ecto_test` database that already recorded version 4
  skips it and never gets the columns - every wrapped-key test then fails with
  `column wrapping_shape does not exist`. Drop that database once
  (`MIX_ENV=test mix ecto.drop -r Encryptor.Ecto.TestRepo`, or
  `dropdb encryptor_ecto_test`) and the next run rebuilds it. CI, which starts
  from an empty server, never sees this.
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
