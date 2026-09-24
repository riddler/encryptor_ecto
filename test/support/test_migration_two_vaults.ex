defmodule Encryptor.Ecto.TestMigrationTwoVaults do
  @moduledoc """
  The tables the two-vaults guide's host writes.

  `library_accounts` holds customer-scoped platform data, `shared_loans` the
  loan records a customer shares under a data agreement, and
  `agreement_keys` the agreement vault's wrapped keys. The customer vault's
  keys go in the default wrapped-key table `Encryptor.Ecto.TestMigrationWrappedKeys`
  already creates.

  `agreement_keys` is the table `mix encryptor.ecto.gen.key_store_migration
  --table agreement_keys` writes, which is how the guide tells a host to
  create it: the same columns and the same two unique indexes as the default
  table, under another name.
  """

  use Ecto.Migration

  @doc "Creates the guide's three tables."
  def change do
    create table(:library_accounts) do
      add(:customer_id, :string, null: false)
      add(:catalog_api_token, :binary)
    end

    create table(:shared_loans) do
      add(:customer_id, :string, null: false)
      add(:agreement_id, :string, null: false)
      add(:patron_email, :binary)
    end

    create table(:agreement_keys) do
      add(:tenant_ref, :string, null: false)
      add(:version, :integer, null: false)
      add(:namespace, :string, null: false)
      add(:name, :string, null: false)
      add(:bits, :integer, null: false)
      add(:wrapped, :binary, null: false)
      add(:wrapping_shape, :string, null: false)
      add(:key_id, :string)
      add(:inserted_at, :utc_datetime)
      add(:updated_at, :utc_datetime)
    end

    create(unique_index(:agreement_keys, [:tenant_ref, :version]))
    create(unique_index(:agreement_keys, [:namespace, :name]))
  end
end
