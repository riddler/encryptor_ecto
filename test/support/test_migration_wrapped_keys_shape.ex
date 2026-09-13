defmodule Encryptor.Ecto.TestMigrationWrappedKeysShape do
  @moduledoc """
  The additive migration an adopter runs, standing in for
  `mix encryptor.ecto.gen.key_store_shape_migration`'s output.

  Same arrangement as `Encryptor.Ecto.TestMigrationWrappedKeys`: this package
  issues no DDL, so the suite plays the host that ran the generated file. The
  two are kept identical by a test that generates the file for this table and
  compares its DDL against this one line by line - without which the `:database`
  tests would be proving a migration no host would ever have run.

  Two `alter` blocks because the column has to exist and be backfilled before
  its default can be taken away, and the default has to go because a permanent
  one turns a host's forgotten column into a row that lies about its shape.
  """

  use Ecto.Migration

  @doc "Adds `wrapping_shape` and `key_id` to the 0.3.0-shaped table."
  def change do
    alter table(:encryptor_wrapped_keys_03) do
      add(:wrapping_shape, :string, null: false, default: "engine_message")
      add(:key_id, :string)
    end

    alter table(:encryptor_wrapped_keys_03) do
      modify(:wrapping_shape, :string,
        null: false,
        default: nil,
        from: {:string, null: false, default: "engine_message"}
      )
    end
  end
end
