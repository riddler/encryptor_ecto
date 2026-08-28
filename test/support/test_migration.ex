defmodule Encryptor.Ecto.TestMigration do
  @moduledoc """
  The one table the `:database`-tagged tests read and write.

  The worked domain is card processing, the same one the vault's own fixtures
  use: a merchant owns rows, and the two encrypted columns are the ones a
  reviewer would expect to be encrypted.

  Both encrypted columns are `:binary` and nothing else, which is ADR-0001
  decision 2 in DDL form - `type/1` returns `:binary` whatever the plaintext
  was, so a migration has one column type to write and no length to guess.
  `:merchant_id` is deliberately *not* encrypted: it is the tenant selector, it
  has to be queryable, and decision 10 says an encrypted column never is.
  """

  use Ecto.Migration

  @doc "Creates the cards table."
  def change do
    create table(:cards) do
      add(:merchant_id, :string, null: false)
      add(:pan, :binary)
      add(:notes, :binary)
    end
  end
end
