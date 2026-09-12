defmodule Encryptor.Ecto.KeyStoreRepoTest do
  @moduledoc """
  `Encryptor.Ecto.KeyStore` against real rows, and the property the bead exists
  for.

  Everything here needs a table: the ordering the candidate list depends on,
  the two typed arms a caller routes on, and the acceptance property - a
  ciphertext moved from one partition into another fails authentication. That
  last one is `encryptor` ADR-0004's worked example made executable, and it is
  only a test at all because the vault, the engine and the store are all real
  here. A mocked provider would assert that a mock refused something.
  """

  use Encryptor.Ecto.RepoCase, async: true

  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.TestKeyStore
  alias Encryptor.Error
  alias Encryptor.Message

  @context %{"table" => "cards", "column" => "pan"}

  describe "decryption_keys/2" do
    # Sabotage: dropped the `order_by` from the query. Postgres returned the
    # rows in insertion order, `encryption_key/2` answered version 1, and every
    # write after a rotation went under the *outgoing* key - which reads back
    # perfectly until the outgoing key is shredded. The conformance suite's
    # head property catches it too; this test says which direction is wrong.
    test "answers every live version, newest first" do
      TestKeyStore.provision!("merchant_7f3", 1)
      TestKeyStore.provision!("merchant_7f3", 2)
      TestKeyStore.provision!("merchant_7f3", 3)

      assert {:ok, [v3, v2, v1]} =
               KeyStore.decryption_keys(TestKeyStore.state(), "merchant_7f3")

      ref = ref(v3)
      assert [v3.name, v2.name, v1.name] == ["t/#{ref}/v3", "t/#{ref}/v2", "t/#{ref}/v1"]
    end

    # Sabotage: resolved every selector to one partition's rows. Both the name
    # and the material comparisons below went red, which is the same mutation
    # the acceptance property catches and the cheapest place to see it.
    test "never answers another tenant's versions" do
      TestKeyStore.provision!("merchant_7f3", 1)
      TestKeyStore.provision!("merchant_a19", 1)

      assert {:ok, [mine]} = KeyStore.decryption_keys(TestKeyStore.state(), "merchant_7f3")
      assert {:ok, [theirs]} = KeyStore.decryption_keys(TestKeyStore.state(), "merchant_a19")

      refute mine.name == theirs.name
      refute digest(mine) == digest(theirs)
    end
  end

  describe "encryption_key/2" do
    test "answers the newest live version" do
      TestKeyStore.provision!("merchant_7f3", 1)
      TestKeyStore.provision!("merchant_7f3", 2)

      assert {:ok, current} = KeyStore.encryption_key(TestKeyStore.state(), "merchant_7f3")
      assert current.name == "t/#{ref(current)}/v2"
      assert current.bits == 256
    end
  end

  describe "the typed arms" do
    # Sabotage: answered `{:ok, []}` for a tenant with no rows. The vault built
    # an empty candidate keyring and the failure surfaced as
    # `{:invalid_key_descriptor, _}` on the first write - a bug report about a
    # descriptor, for a tenant that had simply never been provisioned.
    test "a tenant with no row is a settled unknown_key on both callbacks" do
      state = TestKeyStore.state()

      assert {:error, {:unknown_key, "merchant_none"}} =
               KeyStore.encryption_key(state, "merchant_none")

      assert {:error, {:unknown_key, "merchant_none"}} =
               KeyStore.decryption_keys(state, "merchant_none")
    end

    # A tenant store has no reference to derive for `:default` or for an empty
    # selector, and that is a selector it does not serve rather than a store
    # failure: `:unknown_key` is settled, `:key_unavailable` invites a retry
    # that can never succeed.
    test "a selector no tenant reference exists for is unknown_key, not a raise" do
      state = TestKeyStore.state()

      for selector <- [:default, "", 42] do
        assert {:error, {:unknown_key, ^selector}} = KeyStore.encryption_key(state, selector)
        assert {:error, {:unknown_key, ^selector}} = KeyStore.decryption_keys(state, selector)
      end
    end

    # Sabotage: let `repo.all/1` raise through instead of translating it. The
    # vault reported a `RuntimeError` about a repo that was not started, from
    # inside a decrypt, with no indication that the row might be perfectly
    # fine - which is exactly the three-in-the-morning failure the provider
    # contract carves `:key_unavailable` out of `:decrypt_failed` to prevent.
    test "a store that cannot be asked is key_unavailable, not unknown_key" do
      TestKeyStore.provision!("merchant_7f3", 1)
      state = TestKeyStore.state(repo: TestKeyStore.UnstartedRepo)

      assert {:error, {:key_unavailable, "merchant_7f3"}} =
               KeyStore.encryption_key(state, "merchant_7f3")

      assert {:error, {:key_unavailable, "merchant_7f3"}} =
               KeyStore.decryption_keys(state, "merchant_7f3")
    end

    # Sabotage: returned the unwrap's own `Encryptor.Error` instead of a
    # provider reason. `Encryptor.Vault.Resolve` does not recognize it as one
    # of the five, so it became `{:invalid_key_descriptor, :provider_off_contract}`
    # with the whole error struct - and a wrapped key's failure detail - riding
    # in the `:engine` field a host may well log.
    test "a row that does not unwrap is invalid_key_descriptor, and carries nothing" do
      wrapped = TestKeyStore.provision!("merchant_7f3", 1)
      {:ok, foreign_ref} = tenant_ref("merchant_a19")

      TestKeyStore.insert!(%{
        wrapped
        | tenant_ref: foreign_ref,
          name: "t/#{foreign_ref}/v1"
      })

      assert {:error, {:invalid_key_descriptor, :unwrap_failed}} =
               KeyStore.decryption_keys(TestKeyStore.state(), "merchant_a19")
    end
  end

  describe "the acceptance property" do
    # `encryptor` ADR-0004's worked example, case 1: the bytes are moved into
    # another partition's row and read in that partition's scope.
    #
    # The record's example says the read fails as the engine's
    # `{:key_name_mismatch, _}` - the reading partition's keyring cannot
    # unwrap the data key. That is not where it lands. ADR-0004 decision 6's
    # context comparison runs before the engine is handed a keyring
    # (`Encryptor.Vault.Decrypt.call/4` composes the context and calls
    # `agree/4` ahead of `engine_decrypt/4`), and on a `:tenant` vault
    # `tenant_ref` is derived from `:key` by the vault itself, so the read is
    # refused as `{:encryption_context_mismatch, "tenant_ref"}` with the
    # keyring never consulted. Both are authentication failures and both are
    # `:decrypt_failed` to a caller; which guard fires first is the vault's
    # business and not this provider's. The stale detail in the record is
    # raised in `encryptor` rather than worked around here.
    #
    # That guard alone would refuse the read even against a store handing
    # every partition one shared key, so it does not on its own show that this
    # provider separates keys. The second half of the test is what does: the
    # message names the writing partition's key, and that name is not one the
    # reading partition's candidate list contains.
    #
    # Sabotage: pinned the provider's selector-to-reference step to one
    # partition's reference, so every partition resolved to that partition's
    # rows - one shared key for the whole store. The `refute` below went red:
    # the reading partition's candidate list then contained the very name the
    # message was written under, which is the separation this store exists to
    # provide. The `:decrypt_failed` assertion above stayed green under that
    # same mutation, which is exactly why it is not the acceptance evidence on
    # its own.
    test "a ciphertext moved across partitions fails authentication" do
      TestKeyStore.provision!("merchant_7f3", 1)
      TestKeyStore.provision!("merchant_a19", 1)

      plaintext = "the value in merchant_7f3's column"

      assert {:ok, ciphertext} =
               TestKeyStore.Tenant.encrypt(plaintext,
                 key: "merchant_7f3",
                 encryption_context: @context
               )

      assert {:ok, ^plaintext} =
               TestKeyStore.Tenant.decrypt(ciphertext,
                 key: "merchant_7f3",
                 encryption_context: @context
               )

      assert {:error,
              %Error{
                reason: :decrypt_failed,
                operation: :decrypt,
                engine: {:encryption_context_mismatch, "tenant_ref"}
              }} =
               TestKeyStore.Tenant.decrypt(ciphertext,
                 key: "merchant_a19",
                 encryption_context: @context
               )

      assert {:ok, info} = Message.describe(ciphertext)
      assert [%{key_name: written_under}] = info.encrypted_data_keys

      state = TestKeyStore.state()
      assert {:ok, [writer]} = KeyStore.decryption_keys(state, "merchant_7f3")
      assert {:ok, readers} = KeyStore.decryption_keys(state, "merchant_a19")

      assert written_under == writer.name
      refute written_under in Enum.map(readers, & &1.name)
    end

    # The same substitution against a partition that has no key at all reports
    # the resolution failure rather than collapsing to `:decrypt_failed`. The
    # two are different operational problems and the provider contract is
    # explicit that they stay distinguishable.
    test "and a partition with no key at all reports the resolution failure" do
      TestKeyStore.provision!("merchant_7f3", 1)

      assert {:ok, ciphertext} =
               TestKeyStore.Tenant.encrypt("a value",
                 key: "merchant_7f3",
                 encryption_context: @context
               )

      assert {:error, %Error{reason: {:unknown_key, "merchant_none"}}} =
               TestKeyStore.Tenant.decrypt(ciphertext,
                 key: "merchant_none",
                 encryption_context: @context
               )
    end

    # A rotation adds a version and removes none, so a row written before it
    # still reads: the candidate list is what makes that true, and it is the
    # store's ordering that puts the new key at the head for writes.
    test "a rotation leaves rows written under the outgoing version readable" do
      TestKeyStore.provision!("merchant_7f3", 1)

      assert {:ok, old} =
               TestKeyStore.Tenant.encrypt("written before the rotation",
                 key: "merchant_7f3",
                 encryption_context: @context
               )

      TestKeyStore.provision!("merchant_7f3", 2)

      assert {:ok, "written before the rotation"} =
               TestKeyStore.Tenant.decrypt(old, key: "merchant_7f3", encryption_context: @context)
    end
  end

  defp ref(descriptor) do
    ["t", ref, _version] = String.split(descriptor.name, "/")

    ref
  end

  # A digest rather than the bytes: a tenant master key is key-shaped, and a
  # `refute` that fails prints both sides of what it compared.
  defp digest(descriptor), do: :crypto.hash(:sha256, descriptor.material)

  defp tenant_ref(selector) do
    Encryptor.Envelope.tenant_ref(TestKeyStore.reference_subkey(), selector)
  end
end
