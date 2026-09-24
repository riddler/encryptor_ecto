defmodule Encryptor.Ecto.KeyStoreGcpShredRepoTest do
  @moduledoc """
  The Google Cloud KMS guide's lifecycle, end to end, through the key store.

  `docs/guides/gcp-kms-key-store.md` walks a host through provisioning a
  tenant's key into the wrapped-key table as a `"gcp_kms_ciphertext"` row,
  reading and writing through a tenant vault, and shredding it: destroying
  the `CryptoKey`'s version, then deleting the row. This is that walk as one
  test, against the fake of the provider's HTTP seam, so each answer the
  guide tells a host to expect is one this package actually gives.
  """

  use Encryptor.Ecto.RepoCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.TestGcpKms
  alias Encryptor.Error

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
  test "provision, write, read, destroy the version, delete the row" do
    provisioned = TestGcpKms.provision!(@selector)
    state = TestGcpKms.state()

    assert provisioned.key_id =~ ~r/^t-[a-z2-7]+$/

    assert {:ok, ciphertext} =
             TestGcpKms.Tenant.encrypt("a value", key: @selector, encryption_context: @context)

    assert {:ok, "a value"} =
             TestGcpKms.Tenant.decrypt(ciphertext, key: @selector, encryption_context: @context)

    TestGcpKms.destroyed(provisioned.key_id, true)

    assert {:error, {:key_unavailable, @selector}} = KeyStore.decryption_keys(state, @selector)
    assert {:error, {:key_unavailable, @selector}} = KeyStore.encryption_key(state, @selector)

    assert {:error, %Error{reason: {:key_unavailable, @selector}}} =
             TestGcpKms.Tenant.decrypt(ciphertext, key: @selector, encryption_context: @context)

    # Inside the scheduled-destruction window a restore, while the row still
    # holds its wrapping, makes the value readable again.
    TestGcpKms.destroyed(provisioned.key_id, false)

    assert {:ok, "a value"} =
             TestGcpKms.Tenant.decrypt(ciphertext, key: @selector, encryption_context: @context)

    TestGcpKms.destroyed(provisioned.key_id, true)

    {1, _rows} =
      TestRepo.delete_all(
        from(k in TestGcpKms.table(), where: k.tenant_ref == ^provisioned.tenant_ref)
      )

    assert {:error, {:unknown_key, @selector}} = KeyStore.decryption_keys(state, @selector)
    assert {:error, {:unknown_key, @selector}} = KeyStore.encryption_key(state, @selector)

    assert {:error, %Error{reason: {:unknown_key, @selector}}} =
             TestGcpKms.Tenant.decrypt(ciphertext, key: @selector, encryption_context: @context)

    # A restore after the row is gone brings nothing back: the wrapping was
    # the only stored copy of the key, and the delete removed it.
    TestGcpKms.destroyed(provisioned.key_id, false)

    assert {:error, {:unknown_key, @selector}} = KeyStore.decryption_keys(state, @selector)
  end
end
