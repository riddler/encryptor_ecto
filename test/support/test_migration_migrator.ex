defmodule Encryptor.Ecto.TestMigrationMigrator do
  @moduledoc """
  The migrator's own furniture: the checkpoint table, and a second prefix to
  visit.

  ## The checkpoint table is written here the way a host would write it

  This package issues no DDL (ADR-0002 decision 9), so the checkpoint table
  arrives as generated migration source a host reviews and runs - the
  generator is `ece-5qb`'s. This migration is the test suite standing in for
  that host: the column set is ADR-0002 proposed amendment 5's, and the unique
  index carries the `prefix` component proposed amendment 6 adds. Writing it
  here rather than mocking it is what lets the engine's preflight, its
  `on_conflict` upsert and its per-prefix keying be tested against a real
  table.

  `prefix` is `NOT NULL` with an empty-string default rather than nullable:
  Postgres treats `NULL`s as distinct in a unique index, so a nullable column
  would let two rows exist for the default prefix and the upsert would stop
  finding the row it wrote last time.

  ## The second prefix exists to prove the key needs one

  `tenant_b.cards` is the same table in another schema. Amendment 6's finding
  is that a checkpoint key without a prefix component makes per-prefix runs
  silently skip rows - the second prefix resumes at the first's cursor - and
  a test for that needs two prefixes with rows in both.
  """

  use Ecto.Migration

  @doc "Creates the checkpoint table and the second prefix's cards table."
  def change do
    create table(:encryptor_ecto_migration_checkpoints) do
      add(:plan, :string, null: false)
      add(:schema, :string, null: false)
      add(:field, :string, null: false)
      add(:prefix, :string, null: false, default: "")
      add(:last_id, :string, null: false)
      add(:counts, :map)
      add(:started_at, :utc_datetime)
      add(:updated_at, :utc_datetime)
    end

    create(unique_index(:encryptor_ecto_migration_checkpoints, [:plan, :schema, :field, :prefix]))

    execute("CREATE SCHEMA IF NOT EXISTS tenant_b", "DROP SCHEMA IF EXISTS tenant_b CASCADE")

    create table(:cards, prefix: "tenant_b") do
      add(:merchant_id, :string, null: false)
      add(:pan, :binary)
      add(:notes, :binary)
      add(:holder_name, :binary)
      add(:metadata, :binary)
    end
  end
end
