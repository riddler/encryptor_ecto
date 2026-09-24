defmodule Encryptor.Ecto.TestMigrationRunbook do
  @moduledoc """
  The table the migrate-from-cloak runbook is walked against.

  A generic SaaS host's third-party integrations: each row belongs to a
  workspace, and holds one secret column (`client_secret`) and two token
  columns (`access_token`, `refresh_token`), all three written under one
  legacy key before the migration starts.

  `access_token_hash` is the unkeyed lookup column a legacy host arrives with
  - the runbook's step 7 case that is dropped rather than kept - and
  `access_token_index` is the keyed column that replaces it. Both are here
  from the start because the host's own step 7 migration is not what the
  tests are about; the order of the writes into them is.
  """

  use Ecto.Migration

  @doc "Creates the integrations table."
  def change do
    create table(:integrations) do
      add(:workspace_id, :string, null: false)
      add(:client_secret, :binary)
      add(:access_token, :binary)
      add(:refresh_token, :binary)
      add(:access_token_hash, :binary)
      add(:access_token_index, :binary)
    end
  end
end
