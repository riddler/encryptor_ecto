defmodule Encryptor.Ecto.TestMigrationWrappedKeysPrefix do
  @moduledoc """
  The same wrapped-key table again, in a schema that is not the default one.

  `Encryptor.Ecto.KeyStore`'s `:prefix` option is only shown to work by a
  table the default search path does not reach. The table *name* here is
  deliberately identical to `Encryptor.Ecto.TestMigrationWrappedKeys`'s: if
  the two differed, a test could pass with the prefix ignored and the name
  doing all the work, which is the one thing the option has to be proved
  against.

  The schema is created by this migration rather than by the test, because a
  `SQL.Sandbox` test runs inside a transaction that is rolled back - a schema
  created there would be gone before the next test, and the suite is `async`.

  Nothing in `lib/` issues DDL (ADR-0002 decision 9); this file is the test
  suite standing in for a host, the same way
  `Encryptor.Ecto.TestMigrationWrappedKeys` does.
  """

  use Ecto.Migration

  @prefix "encryptor_test_prefix"

  @doc "The schema name the prefixed table lives in."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "Creates the schema and the prefixed wrapped-key table."
  def change do
    execute(
      "CREATE SCHEMA IF NOT EXISTS #{@prefix}",
      "DROP SCHEMA IF EXISTS #{@prefix} CASCADE"
    )

    create table(:encryptor_wrapped_keys, prefix: @prefix) do
      add(:tenant_ref, :string, null: false)
      add(:version, :integer, null: false)
      add(:namespace, :string, null: false)
      add(:name, :string, null: false)
      add(:bits, :integer, null: false)
      add(:wrapped, :binary, null: false)
      add(:wrapping_shape, :string, null: false)
      add(:key_id, :string)
      add(:inserted_at, :utc_datetime)
      add(:updated_at, :utc_datetime)
    end

    create(unique_index(:encryptor_wrapped_keys, [:tenant_ref, :version], prefix: @prefix))
    create(unique_index(:encryptor_wrapped_keys, [:namespace, :name], prefix: @prefix))
  end
end
