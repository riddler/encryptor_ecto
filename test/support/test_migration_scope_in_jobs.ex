defmodule Encryptor.Ecto.TestMigrationScopeInJobs do
  @moduledoc """
  The tables the scope-in-jobs guide's host writes.

  `patrons` holds the rows the request, the `Task` and the background job
  write and read under the process scope; `loan_views` is the projector's read
  model, written and read under the projector's own resolver. Both keys come
  from `Encryptor.Ecto.TestVaults.Merchant`, so there is no key table here.
  """

  use Ecto.Migration

  @doc "Creates the guide's two tables."
  def change do
    create table(:patrons) do
      add(:library_id, :string, null: false)
      add(:email, :binary)
    end

    create table(:loan_views) do
      add(:library_id, :string, null: false)
      add(:title, :string)
      add(:patron_email, :binary)
    end
  end
end
