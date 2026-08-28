defmodule Encryptor.Ecto.TestMigrationSignups do
  @moduledoc """
  The signup wizard's table, which the migrator's adoption tests read.

  A second worked domain beside the cards table on purpose: adopting
  encryption on a column that was never encrypted is not a data-only
  migration (ADR-0002 decision 8). `email` is the plaintext column the table
  has always had, `email_encrypted` is the binary one the host's own DDL
  added, and the backfill leg is the only part of that dance the migrator
  performs - the expand and the contract are the host's own migrations.

  `variant_notes` is a global field: it belongs to the wizard's A/B variant
  rather than to any one tenant, which is the `tenant :none` case a plan has
  to be able to express.
  """

  use Ecto.Migration

  @doc "Creates the signups table."
  def change do
    create table(:signups) do
      add(:variant, :string)
      add(:email, :string)
      add(:email_encrypted, :binary)
      add(:variant_notes, :binary)
    end
  end
end
