defmodule Encryptor.Ecto.TestMigrationCardholders do
  @moduledoc """
  A table with blind index columns beside its encrypted ones, for the
  migrator's folded-index tests.

  The index columns are ordinary `:binary` columns the host's own DDL adds
  (ADR-0003 decision 5), which is all this migration is standing in for.
  `email` is a per-merchant field on the tenant vault; `nickname` is a global
  field on the vault that encrypts and refuses to derive, so an index folded
  into its rewrite has a failure to report that the rewrite itself does not
  share.
  """

  use Ecto.Migration

  @doc "Creates the cardholders table."
  def change do
    create table(:cardholders) do
      add(:merchant_id, :string, null: false)
      add(:email, :binary)
      add(:email_index, :binary)
      add(:nickname, :binary)
      add(:nickname_index, :binary)
    end
  end
end
