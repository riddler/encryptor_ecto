defmodule Encryptor.Ecto.TestMigrationWrappedKeys03Row do
  @moduledoc """
  The row a 0.3.0 adopter already had, written before the columns existed.

  A data migration rather than a fixture inserted from a test, and deliberately
  so: the property ADR-0005 decision 3 asserts is about rows that were in the
  table *before* the additive migration ran, and a row a test inserts afterwards
  cannot show it. Written the way the host writes it -
  `Encryptor.Envelope.provision/3` under the root vault, then an `INSERT` - so
  the wrapping is a real engine message and the resolution test that reads it
  back is resolving something.

  It runs between `Encryptor.Ecto.TestMigrationWrappedKeys03` and
  `Encryptor.Ecto.TestMigrationWrappedKeysShape`, which is where a real row
  would have been written.
  """

  use Ecto.Migration

  alias Encryptor.Ecto.TestKeyStore
  alias Encryptor.Envelope

  @selector "merchant_03"

  @doc "The selector the pre-upgrade row was provisioned for."
  @spec selector() :: String.t()
  def selector, do: @selector

  @doc "Writes one 0.3.0-era row."
  def up do
    {:ok, wrapped} =
      Envelope.provision(TestKeyStore.Root, @selector,
        reference_subkey: TestKeyStore.reference_subkey(),
        version: 1
      )

    now = DateTime.truncate(DateTime.utc_now(), :second)

    {1, _rows} =
      repo().insert_all("encryptor_wrapped_keys_03", [
        [
          tenant_ref: wrapped.scope_ref,
          version: wrapped.version,
          namespace: wrapped.namespace,
          name: wrapped.name,
          bits: wrapped.bits,
          wrapped: wrapped.wrapped,
          inserted_at: now,
          updated_at: now
        ]
      ])

    :ok
  end

  @doc "Removes it."
  def down do
    repo().query!("DELETE FROM encryptor_wrapped_keys_03")

    :ok
  end
end
