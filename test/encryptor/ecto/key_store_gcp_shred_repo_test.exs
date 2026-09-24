defmodule Encryptor.Ecto.KeyStoreGcpShredRepoTest do
  @moduledoc """
  The Google Cloud KMS guide's lifecycle, end to end, through the key store.

  `docs/guides/gcp-kms-key-store.md` walks a host through provisioning a
  scope's key into the wrapped-key table as a `"gcp_kms_ciphertext"` row,
  reading and writing through a scoped vault, and shredding it: destroying
  the `CryptoKey`'s version, then deleting the row with
  `Encryptor.Ecto.KeyStore.shred/3`. This is that walk as one
  test, against the fake of the provider's HTTP seam, so each answer the
  guide tells a host to expect is one this package actually gives.
  """

  use Encryptor.Ecto.RepoCase, async: true

  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.KeyStore.Shred
  alias Encryptor.Ecto.TestGcpKms
  alias Encryptor.Ecto.TestKeyStore
  alias Encryptor.Error
  alias Encryptor.Provider.GcpKms

  @context %{"table" => "cards", "column" => "pan"}
  @selector "merchant_shredded"

  # The destroyed-version answer is ADR-0005 Amendment A5's, at proposed: the
  # provider merges a refused `Decrypt` with an unreachable service into
  # `{:key_unavailable, selector}`, and the store returns it unrelabelled.
  # The row delete then turns it into the settled `{:unknown_key, selector}`.
  #
  # Sabotage: relabelled the delegate's failure in `KeyStore.unwrap_row/4`'s
  # GCP clause to `{:invalid_key_descriptor, :unwrap_failed}`; the first
  # post-destroy assertion went red on that term. Separately, made the fake's
  # `destroyed/2` a no-op; the same assertion went red on `{:ok, [_]}`.
  # Separately, made `KeyStore.shred/3` resolve the scope's keys through
  # `decryption_keys/2` before its delete; the `shred/3` assertion went red
  # on `{:error, {:key_unavailable, "merchant_shredded"}}`.
  test "provision, write, read, destroy the version, delete the row" do
    provisioned = TestGcpKms.provision!(@selector)
    state = TestGcpKms.state()

    assert provisioned.key_id =~ ~r/^t-[a-z2-7]+$/

    assert {:ok, ciphertext} =
             TestGcpKms.Scope.encrypt("a value", key: @selector, encryption_context: @context)

    assert {:ok, "a value"} =
             TestGcpKms.Scope.decrypt(ciphertext, key: @selector, encryption_context: @context)

    TestGcpKms.destroyed(provisioned.key_id, true)

    assert {:error, {:key_unavailable, @selector}} = KeyStore.decryption_keys(state, @selector)
    assert {:error, {:key_unavailable, @selector}} = KeyStore.encryption_key(state, @selector)

    assert {:error, %Error{reason: {:key_unavailable, @selector}}} =
             TestGcpKms.Scope.decrypt(ciphertext, key: @selector, encryption_context: @context)

    # Inside the scheduled-destruction window a restore, while the row still
    # holds its wrapping, makes the value readable again.
    TestGcpKms.destroyed(provisioned.key_id, false)

    assert {:ok, "a value"} =
             TestGcpKms.Scope.decrypt(ciphertext, key: @selector, encryption_context: @context)

    TestGcpKms.destroyed(provisioned.key_id, true)

    # The guide's Step 6 row delete, as written there: `shred/3` on the
    # scoped vault, after the destroy. It reads version numbers and never
    # unwraps, so the destroyed version does not refuse it.
    assert {:ok, %Shred{procedure: :scope, versions: [1], remaining: [], scope_ref: scope_ref}} =
             KeyStore.shred(TestGcpKms.Scope, @selector, version: :all)

    assert scope_ref == provisioned.scope_ref

    assert {:error, {:unknown_key, @selector}} = KeyStore.decryption_keys(state, @selector)
    assert {:error, {:unknown_key, @selector}} = KeyStore.encryption_key(state, @selector)

    assert {:error, %Error{reason: {:unknown_key, @selector}}} =
             TestGcpKms.Scope.decrypt(ciphertext, key: @selector, encryption_context: @context)

    # A restore after the row is gone brings nothing back: the wrapping was
    # the only stored copy of the key, and the delete removed it.
    TestGcpKms.destroyed(provisioned.key_id, false)

    assert {:error, {:unknown_key, @selector}} = KeyStore.decryption_keys(state, @selector)
  end

  # The guide's Step 4 insert, as written there: `GcpKms.provision/2` answers
  # `:scope_ref`, and the kept column is `tenant_ref` (ADR-0006 decision 3).
  #
  # Sabotage: dropped the `Map.pop/2` and inserted the provider's map as it
  # comes back, which is what the guide said before this fix; the insert
  # raised `Postgrex.Error` on the missing `scope_ref` column.
  test "the guide's provisioning insert writes a row the key store reads" do
    selector = "merchant_guided"

    {:ok, gcp} =
      GcpKms.init(
        TestGcpKms.opts() ++
          [reference_subkey: TestKeyStore.reference_subkey(), store: fn _ref -> {:ok, []} end]
      )

    {:ok, row} = GcpKms.provision(gcp, selector)
    {ref, row} = Map.pop(row, :scope_ref)

    {1, _rows} =
      TestRepo.insert_all(TestGcpKms.table(), [
        row
        |> Map.put(:tenant_ref, ref)
        |> Map.put(:wrapping_shape, "gcp_kms_ciphertext")
        |> Map.to_list()
      ])

    assert {:ok, [_descriptor]} = KeyStore.decryption_keys(TestGcpKms.state(), selector)
  end
end
