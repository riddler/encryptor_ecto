defmodule Encryptor.Ecto.TestMigrationRunbookParallel do
  @moduledoc """
  The migrate-from-cloak runbook's table, given the parallel-column shape.

  A host leaving a single-key library by a parallel column adds one binary
  column beside each encrypted one, named `<field>_encrypted` by the guide's
  convention, and runs the pass `into:` it. This is that host's own
  expand migration: the package ships no DDL, so the fixture writes it the
  way the guide tells a host to.

  It is a migration of its own rather than an edit to
  `Encryptor.Ecto.TestMigrationRunbook`, because a local test database that
  has already recorded that version would skip an in-place edit and never get
  the columns.
  """

  use Ecto.Migration

  @doc "Adds the three `_encrypted` columns to the integrations table."
  def change do
    alter table(:integrations) do
      add(:client_secret_encrypted, :binary)
      add(:access_token_encrypted, :binary)
      add(:refresh_token_encrypted, :binary)
    end
  end
end
