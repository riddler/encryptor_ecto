defmodule Encryptor.Ecto.TestMigrationLiveKms do
  @moduledoc """
  The tables the live KMS suites write their encrypted fields into.

  One table per suite, so a row the Cloud KMS suite wrote is never read
  through the AWS KMS suite's vault: `Encryptor.Ecto.GcpKmsLiveTest` writes
  `live_gcp_kms_values` through a key store whose rows Cloud KMS wraps, and
  `Encryptor.Ecto.AwsKmsLiveTest` writes `live_aws_kms_values` through a
  vault on `Encryptor.Provider.Kms`. The default run creates both and writes
  neither.
  """

  use Ecto.Migration

  @doc "Creates the two suites' tables."
  def change do
    create table(:live_gcp_kms_values) do
      add(:scope_id, :string, null: false)
      add(:value, :binary)
    end

    create table(:live_aws_kms_values) do
      add(:scope_id, :string, null: false)
      add(:value, :binary)
    end
  end
end
