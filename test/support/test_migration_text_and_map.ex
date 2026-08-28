defmodule Encryptor.Ecto.TestMigrationTextAndMap do
  @moduledoc """
  The columns `Encryptor.Ecto.String` and `Encryptor.Ecto.Map` are declared on.

  A second migration rather than two more `add` lines in
  `Encryptor.Ecto.TestMigration`: an existing test database has already run
  version 0, and a migrator skips a version it has already applied, so editing
  the first migration would leave a developer's database without the columns
  and only CI's fresh one with them.

  Both are `:binary`, which is the point worth having a database to prove.
  `:holder_name` is text and `:metadata` is a map, and neither gets a `:text`
  or a `:jsonb` column - `type/1` returns `:binary` whatever the plaintext was
  (ADR-0001 decision 2), so what the database stores is ciphertext and nothing
  it could index, search or validate.
  """

  use Ecto.Migration

  @doc "Adds the text and map columns to the cards table."
  def change do
    alter table(:cards) do
      add(:holder_name, :binary)
      add(:metadata, :binary)
    end
  end
end
