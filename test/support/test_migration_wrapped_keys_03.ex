defmodule Encryptor.Ecto.TestMigrationWrappedKeys03 do
  @moduledoc """
  A wrapped-key table exactly as 0.3.0's generator wrote it: six columns and
  timestamps, no `wrapping_shape`, no `key_id`.

  It exists so ADR-0005 decision 7's upgrade path has a subject. The suite's
  own `Encryptor.Ecto.TestMigrationWrappedKeys` is the table a *fresh* adopter
  gets, and a fresh table proves nothing about an adopter who already has nine
  thousand rows. This one, the row
  `Encryptor.Ecto.TestMigrationWrappedKeys03Row` writes into it, and the
  additive migration in `Encryptor.Ecto.TestMigrationWrappedKeysShape` are the
  three steps of that adopter's upgrade, in the order they happen.

  The DDL below is a frozen copy and is not kept in step with the generator:
  its whole purpose is to be what the generator used to write.
  """

  use Ecto.Migration

  @doc "Creates the 0.3.0-shaped wrapped-key table."
  def change do
    create table(:encryptor_wrapped_keys_03) do
      add(:tenant_ref, :string, null: false)
      add(:version, :integer, null: false)
      add(:namespace, :string, null: false)
      add(:name, :string, null: false)
      add(:bits, :integer, null: false)
      add(:wrapped, :binary, null: false)
      add(:inserted_at, :utc_datetime)
      add(:updated_at, :utc_datetime)
    end

    create(unique_index(:encryptor_wrapped_keys_03, [:tenant_ref, :version]))
    create(unique_index(:encryptor_wrapped_keys_03, [:namespace, :name]))
  end
end
