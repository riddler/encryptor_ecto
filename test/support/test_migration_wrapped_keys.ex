defmodule Encryptor.Ecto.TestMigrationWrappedKeys do
  @moduledoc """
  The wrapped-key table, written here the way a host would write it.

  This package issues no DDL (ADR-0002 decision 9), so the table arrives as
  generated migration source a host reviews and runs - the generator is
  `mix encryptor.ecto.gen.key_store_migration`. This migration is the test
  suite standing in for that host, exactly as
  `Encryptor.Ecto.TestMigrationMigrator` does for the checkpoint table. Writing
  it here rather than mocking it is what lets the provider's query, its
  ordering, and both unique indexes be exercised against a real table.

  The column set is the six fields of `Encryptor.Envelope.WrappedKey`, plus
  ADR-0005's `wrapping_shape` and `key_id`, plus timestamps, and it is kept
  identical to `Mix.Tasks.Encryptor.Ecto.Gen.KeyStoreMigration.source/2` by a
  test that reads the generator's output and asserts each line of it.

  This is the *fresh* table a new adopter gets. The one an adopter created
  under 0.3.0, and the additive migration that brings it here, are
  `Encryptor.Ecto.TestMigrationWrappedKeys03` and
  `Encryptor.Ecto.TestMigrationWrappedKeysShape`.
  """

  use Ecto.Migration

  @doc "Creates the wrapped-key table."
  def change do
    create table(:encryptor_wrapped_keys) do
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

    create(unique_index(:encryptor_wrapped_keys, [:tenant_ref, :version]))
    create(unique_index(:encryptor_wrapped_keys, [:namespace, :name]))
  end
end
