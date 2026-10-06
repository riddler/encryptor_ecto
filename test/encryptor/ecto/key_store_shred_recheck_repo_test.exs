defmodule Encryptor.Ecto.KeyStoreShredRecheckRepoTest do
  @moduledoc """
  P3's re-check for a remaining row, with a version provisioned while the
  shred runs.

  `FOR UPDATE` locks the rows the shred read and does not stop an insert
  beside them, so a version another transaction commits between the read and
  the delete is not in the locked set. The test cannot pause the shred
  between its statements, so it puts the insert there with a trigger: after
  the shred's first delete, the trigger inserts a new version of the same
  scope, which is what a concurrent `Encryptor.Envelope.provision/3` that
  committed at that moment leaves behind. Under `READ COMMITTED` the shred's
  next statement sees a row committed by another transaction exactly as it
  sees one written earlier in its own, so the trigger stands in for the
  other transaction faithfully for this purpose.

  Not async: the trigger is DDL on the shared key-store table, and although
  the sandbox rolls it back, it holds a lock on that table until then.
  """

  use Encryptor.Ecto.RepoCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.KeyStore.Shred
  alias Encryptor.Ecto.TestKeyStore

  @late_version 99

  setup do
    # After a delete of the key-store table, insert one new version of the
    # deleted scope - once: a delete whose rows include that version (the
    # re-check taking it) or a delete of nothing inserts nothing.
    TestRepo.query!("""
    CREATE FUNCTION ece_late_provision() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF EXISTS (SELECT 1 FROM gone)
         AND NOT EXISTS (SELECT 1 FROM gone WHERE version = #{@late_version}) THEN
        INSERT INTO encryptor_wrapped_keys
          (scope_ref, version, namespace, name, bits, wrapped, wrapping_shape, key_id)
        SELECT scope_ref, #{@late_version}, namespace, name || '-late', bits, wrapped,
               wrapping_shape, key_id
          FROM gone ORDER BY version DESC LIMIT 1;
      END IF;
      RETURN NULL;
    END
    $$
    """)

    TestRepo.query!("""
    CREATE TRIGGER ece_late_provision AFTER DELETE ON encryptor_wrapped_keys
      REFERENCING OLD TABLE AS gone
      FOR EACH STATEMENT EXECUTE FUNCTION ece_late_provision()
    """)

    :ok
  end

  # Sabotage: made `recheck/5`'s P3 clause answer `{doomed, []}` without its
  # delete. Version 99 survived, the record still said `remaining: []`, and
  # the `versions: [1, 2, 99]` match went red on `[1, 2]`.
  test "P3 deletes a version committed after its read, and names it in the record" do
    selector = "merchant_p3_late"
    TestKeyStore.provision!(selector, 1)
    TestKeyStore.provision!(selector, 2)

    assert {:ok, %Shred{procedure: :scope, versions: [1, 2, @late_version], remaining: []}} =
             KeyStore.shred(TestKeyStore.Scope, selector, version: :all)

    assert rows(selector) == []
  end

  # P4 names one version and deletes that one only; the version the trigger
  # adds is a live key the call was never asked about.
  #
  # Sabotage: made `recheck/5`'s P3 clause match any `which` and any
  # `remaining`. P4 deleted the scope's newest version and the late one, and
  # the record match went red on `versions: [1, 2, 99], remaining: []`.
  test "P4 leaves a version committed after its read alone" do
    selector = "merchant_p4_late"
    TestKeyStore.provision!(selector, 1)
    TestKeyStore.provision!(selector, 2)

    assert {:ok, %Shred{procedure: :version, versions: [1], remaining: [2]}} =
             KeyStore.shred(TestKeyStore.Scope, selector, version: 1)

    assert rows(selector) == [2, @late_version]
  end

  defp rows(selector) do
    {:ok, ref} = Encryptor.Envelope.scope_ref(TestKeyStore.reference_subkey(), selector)

    TestRepo.all(
      from(k in KeyStore.default_table(),
        where: k.scope_ref == ^ref,
        order_by: [asc: k.version],
        select: k.version
      )
    )
  end
end
