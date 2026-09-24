defmodule Encryptor.Ecto.TestMigrationSuspensions do
  @moduledoc """
  The suspension table, written here the way a host would write it.

  The generator is `mix encryptor.ecto.gen.suspension_store_migration`; this
  migration stands in for the host that ran it, as
  `Encryptor.Ecto.TestMigrationWrappedKeys` does for the key store, and a
  test compares its DDL lines with the generator's output so the two cannot
  drift.
  """

  use Ecto.Migration

  @doc "Creates the suspension table."
  def change do
    create table(:encryptor_suspensions) do
      add(:vault, :string, null: false)
      add(:selector, :string, null: false)
      add(:inserted_at, :utc_datetime, null: false)
    end

    create(unique_index(:encryptor_suspensions, [:vault, :selector]))
  end
end
