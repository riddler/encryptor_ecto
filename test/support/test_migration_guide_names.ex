defmodule Encryptor.Ecto.TestMigrationGuideNames do
  @moduledoc """
  Renames the two guides' tables and columns to the domain-free names their
  schemas use.

  `Encryptor.Ecto.TestMigrationTwoVaults` and
  `Encryptor.Ecto.TestMigrationScopeInJobs` created these tables under the
  names the guides used before they were made domain-free. Editing those two
  migrations in place would leave a local database that already recorded them
  without the new names, so the rename is a migration of its own: a fresh
  database creates the old names and renames them here, and an existing one
  is renamed in place. A table rename keeps its index names, so the
  `grant_keys` indexes still carry the `agreement_keys` prefix; nothing
  reads them by name.
  """

  use Ecto.Migration

  @doc "Renames the two-vaults tables and the scope-in-jobs tables."
  def change do
    rename(table(:library_accounts), to: table(:owner_records))
    rename(table(:owner_records), :customer_id, to: :owner_id)
    rename(table(:owner_records), :catalog_api_token, to: :secret_token)

    rename(table(:shared_loans), to: table(:grant_records))
    rename(table(:grant_records), :customer_id, to: :owner_id)
    rename(table(:grant_records), :agreement_id, to: :grant_id)
    rename(table(:grant_records), :patron_email, to: :note)

    rename(table(:agreement_keys), to: table(:grant_keys))

    rename(table(:patrons), to: table(:items))
    rename(table(:items), :library_id, to: :owner_id)
    rename(table(:items), :email, to: :note)

    rename(table(:loan_views), to: table(:item_views))
    rename(table(:item_views), :library_id, to: :owner_id)
    rename(table(:item_views), :patron_email, to: :note)
  end
end
