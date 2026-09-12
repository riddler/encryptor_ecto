defmodule Encryptor.Ecto.TestMigrationScalars do
  @moduledoc """
  The columns the six scalar types are declared on.

  A migration of its own rather than more `add` lines in an earlier one: an
  existing test database has already run versions 0 to 4, and a migrator skips
  a version it has already applied, so editing an earlier migration would leave
  a developer's database without the columns and only CI's fresh one with them.

  Every column is `:binary` - not `:integer`, `:numeric`, `:date`, `:time` or
  `:timestamp` - which is the point worth having a database to prove. `type/1`
  returns `:binary` whatever the plaintext was (ADR-0001 decision 2), so the
  database applies none of its own validation, ordering or range checks to
  these values, and a migration that reached for the natural column type would
  reject the ciphertext outright.
  """

  use Ecto.Migration

  @doc "Creates the readings table."
  def change do
    create table(:readings) do
      add(:merchant_id, :string, null: false)
      add(:retry_count, :binary)
      add(:fee_rate, :binary)
      add(:date_of_birth, :binary)
      add(:contact_window_opens_at, :binary)
      add(:agreed_at, :binary)
      add(:verified_at, :binary)
    end
  end
end
