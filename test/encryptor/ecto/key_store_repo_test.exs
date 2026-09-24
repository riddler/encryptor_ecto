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

  import Ecto.Query, only: [from: 2]

  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.TestGcpKms
  alias Encryptor.Ecto.TestKeyStore
  alias Encryptor.Ecto.TestMigrationWrappedKeys03Row
  alias Encryptor.Ecto.TestMigrationWrappedKeysPrefix
  alias Encryptor.Error
  alias Encryptor.Message
  alias Encryptor.Provider.GcpKms

  @context %{"table" => "cards", "column" => "pan"}

  # The 0.3.0-shaped table, its pre-upgrade row's selector, and the migrations
  # that built both: `Encryptor.Ecto.TestMigrationWrappedKeys03`,
  # `...03Row` and `...Shape`, run in that order from
  # `Encryptor.Ecto.TestRepo`'s list.
  @legacy_table "encryptor_wrapped_keys_03"
  @legacy_selector TestMigrationWrappedKeys03Row.selector()

  # The schema `Encryptor.Ecto.TestMigrationWrappedKeysPrefix` put a
  # same-named wrapped-key table in.
  @prefix TestMigrationWrappedKeysPrefix.prefix()

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

    # Sabotage: resolved every selector to one partition's rows. Each of the
    # name and material comparisons below goes red on its own - ExUnit stops
    # this test at the first failing assertion, so a single run shows only the
    # first of them - which is the same mutation the acceptance property
    # catches and the cheapest place to see it.
    test "never answers another scope's versions" do
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
    # Sabotage: answered `{:ok, []}` for a scope with no rows. The vault built
    # an empty candidate keyring and the failure surfaced as
    # `{:invalid_key_descriptor, _}` on the first write - a bug report about a
    # descriptor, for a scope that had simply never been provisioned.
    test "a scope with no row is a settled unknown_key on both callbacks" do
      state = TestKeyStore.state()

      assert {:error, {:unknown_key, "merchant_none"}} =
               KeyStore.encryption_key(state, "merchant_none")

      assert {:error, {:unknown_key, "merchant_none"}} =
               KeyStore.decryption_keys(state, "merchant_none")
    end

    # A scope store has no reference to derive for `:default` or for an empty
    # selector, and that is a selector it does not serve rather than a store
    # failure: `:unknown_key` is settled, `:key_unavailable` invites a retry
    # that can never succeed.
    test "a selector no scope reference exists for is unknown_key, not a raise" do
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
      {:ok, foreign_ref} = scope_ref("merchant_a19")

      TestKeyStore.insert!(%{
        wrapped
        | scope_ref: foreign_ref,
          name: "t/#{foreign_ref}/v1"
      })

      assert {:error, {:invalid_key_descriptor, :unwrap_failed}} =
               KeyStore.decryption_keys(TestKeyStore.state(), "merchant_a19")
    end
  end

  describe "a version that will not unwrap" do
    # Sabotage: put `reduce_while`'s halt back, so one failed unwrap ended the
    # whole list. This assertion went red with `{:invalid_key_descriptor,
    # :unwrap_failed}` - every write for the scope refused because of a
    # wrapping from a rotation ago, which is the outage this bead exists to
    # remove.
    test "an older one does not block a write" do
      TestKeyStore.provision!("merchant_7f3", 2)
      corrupt!("merchant_7f3", 1)

      assert {:ok, current} = KeyStore.encryption_key(TestKeyStore.state(), "merchant_7f3")
      assert current.name == "t/#{ref(current)}/v2"
    end

    # The decided read semantics: skipped, not fatal. A version that will not
    # unwrap is already a version nothing can be decrypted under, so removing
    # it from the candidate list costs a caller nothing - and halting would
    # have made every value the scope ever wrote unreadable to protect the
    # subset written under this one.
    test "an older one is skipped, and the versions that do unwrap still answer" do
      TestKeyStore.provision!("merchant_7f3", 3)
      TestKeyStore.provision!("merchant_7f3", 2)
      corrupt!("merchant_7f3", 1)

      assert {:ok, [v3, v2]} = KeyStore.decryption_keys(TestKeyStore.state(), "merchant_7f3")

      ref = ref(v3)
      assert [v3.name, v2.name] == ["t/#{ref}/v3", "t/#{ref}/v2"]
    end

    # The newest row is the one a write would go under, so a write has to
    # fail - but reads of everything written before it keep working. The two
    # callbacks part company here on purpose, which is why `encryption_key/2`
    # is no longer documented as the head of the decryption list.
    test "the newest one blocks writes and leaves reads alone" do
      TestKeyStore.provision!("merchant_7f3", 1)
      corrupt!("merchant_7f3", 2)

      state = TestKeyStore.state()

      assert {:error, {:invalid_key_descriptor, :unwrap_failed}} =
               KeyStore.encryption_key(state, "merchant_7f3")

      assert {:ok, [only]} = KeyStore.decryption_keys(state, "merchant_7f3")
      assert only.name == "t/#{ref(only)}/v1"
    end

    # The other half of the decision, end to end and through the vault: a
    # value written under the version that later stopped unwrapping is the one
    # thing that does not read back, and everything else the scope has keeps
    # working. That is the whole trade - the loss is scoped to the rows whose
    # key is genuinely gone, rather than spread over every row the scope
    # owns, which is what halting on the bad version used to do.
    #
    # Sabotage: put the halt back. The value written *after* the break stopped
    # reading back too - the scope's whole history went dark because one
    # wrapping from before the rotation no longer opened.
    test "and reads of rows written under it fail, while the scope keeps working" do
      TestKeyStore.provision!("merchant_7f3", 1)

      assert {:ok, old} =
               TestKeyStore.Scope.encrypt("written under the version that broke",
                 key: "merchant_7f3",
                 encryption_context: @context
               )

      TestKeyStore.provision!("merchant_7f3", 2)
      break_wrapping!("merchant_7f3", 1)

      assert {:error, %Error{reason: :decrypt_failed}} =
               TestKeyStore.Scope.decrypt(old, key: "merchant_7f3", encryption_context: @context)

      assert {:ok, current} =
               TestKeyStore.Scope.encrypt("written after",
                 key: "merchant_7f3",
                 encryption_context: @context
               )

      assert {:ok, "written after"} =
               TestKeyStore.Scope.decrypt(current,
                 key: "merchant_7f3",
                 encryption_context: @context
               )
    end

    # Nothing was skipped into silence: with no row left to answer with, the
    # newest failing row's own reason is what arrives, which is the same term
    # a store holding only that row returned before the skip existed.
    test "and when no version unwraps, the newest one's reason is the answer" do
      corrupt!("merchant_7f3", 1)
      TestKeyStore.provision!("merchant_7f3", 2, wrapping_shape: "vault_transit")

      assert {:error, {:invalid_key_descriptor, {:unknown_wrapping_shape, "vault_transit"}}} =
               KeyStore.decryption_keys(TestKeyStore.state(), "merchant_7f3")
    end
  end

  describe "a permanent misconfiguration" do
    # Sabotage: restored the bare rescue. This raised no more - it answered
    # `{:key_unavailable, "merchant_7f3"}`, telling an operator to wait for a
    # table that nobody is going to create by waiting, and throwing away the
    # `Postgrex.Error` that names it.
    test "a table that was never migrated raises rather than reporting key_unavailable" do
      state = TestKeyStore.state(table: "encryptor_wrapped_keys_absent")

      assert_raise Postgrex.Error, fn -> KeyStore.decryption_keys(state, "merchant_7f3") end
    end

    # Column drift, reproduced against a real table with real columns that are
    # not these ones. It is the arm ADR-0005 decision 7 names: a 0.4.0 store
    # reading a 0.3.0 table selects `wrapping_shape` and does not find it.
    test "a table whose columns are not these ones raises" do
      state = TestKeyStore.state(table: "schema_migrations")

      assert_raise Postgrex.Error, fn -> KeyStore.encryption_key(state, "merchant_7f3") end
    end

    # A prefix naming a schema that does not exist is the same class of
    # mistake as a table that does not: a typo in a deploy, permanent until
    # somebody fixes it.
    test "a prefix naming a schema that does not exist raises" do
      state = TestKeyStore.state(prefix: "encryptor_test_no_such_schema")

      assert_raise Postgrex.Error, fn -> KeyStore.decryption_keys(state, "merchant_7f3") end
    end
  end

  describe "the schema prefix" do
    # The prefixed table carries the *same name* as the default-schema one, so
    # nothing here can pass on the table name alone: the only thing that can
    # separate the two rows below is the prefix reaching the adapter.
    #
    # Sabotage: dropped `:prefix` from the query options. Both assertions went
    # red at once - the prefixed row was invisible and the default-schema row
    # answered every lookup, which is a store quietly serving another
    # schema's keys.
    test "routes every query to the schema the table was placed in" do
      TestKeyStore.provision!("merchant_7f3", 1, prefix: @prefix)

      state = TestKeyStore.state(prefix: @prefix)

      assert {:ok, [descriptor]} = KeyStore.decryption_keys(state, "merchant_7f3")
      assert {:ok, ^descriptor} = KeyStore.encryption_key(state, "merchant_7f3")
    end

    test "and a store without it does not see that schema's rows" do
      TestKeyStore.provision!("merchant_7f3", 1, prefix: @prefix)

      assert {:error, {:unknown_key, "merchant_7f3"}} =
               KeyStore.decryption_keys(TestKeyStore.state(), "merchant_7f3")
    end

    test "and a store with it does not see the default schema's rows" do
      TestKeyStore.provision!("merchant_7f3", 1)

      assert {:error, {:unknown_key, "merchant_7f3"}} =
               KeyStore.decryption_keys(TestKeyStore.state(prefix: @prefix), "merchant_7f3")
    end
  end

  describe "dispatch on the row's wrapping shape" do
    # Sabotage: ignored `wrapping_shape` and sent every row down
    # `Envelope.unwrap/2`, as 0.3.0 did. The GCP row below unwrapped perfectly -
    # its `wrapped` really is an engine message here - and the test went red on
    # the expected error rather than on a decrypt failure, which is the whole
    # point: a store that guesses gets it right in the fixture and wrong in
    # production, where the bytes are a GCP ciphertext.
    #
    # The store here is configured without `:gcp_kms`, so the GCP branch has
    # no client and answers the refusal ADR-0005's Amendment A keeps for that
    # configuration. With the client configured, the row is served: see
    # "a gcp_kms_ciphertext row, with the GCP branch configured" below.
    test "a gcp_kms_ciphertext row is not unwrapped as an engine message, and without :gcp_kms is refused" do
      TestKeyStore.provision!("merchant_7f3", 1,
        wrapping_shape: "gcp_kms_ciphertext",
        key_id: "projects/p/locations/l/keyRings/r/cryptoKeys/k"
      )

      assert {:error, {:invalid_key_descriptor, {:unsupported_wrapping_shape, shape}}} =
               KeyStore.decryption_keys(TestKeyStore.state(), "merchant_7f3")

      assert shape == "gcp_kms_ciphertext"
    end

    # The two shapes coexist for the length of a host's migration, which is why
    # ADR-0005 decision 5 dispatches per row rather than per store: one setting
    # for the whole store would make the mixed window unrepresentable. Both rows
    # below are each produced by their own path - a root-vault engine message
    # and a GCP KMS ciphertext - and one store configured with both clients
    # serves both, in one scope and across two.
    #
    # Sabotage: sent the GCP row down the refusal arm whatever the
    # configuration. `merchant_a19` answered `{:unsupported_wrapping_shape,
    # "gcp_kms_ciphertext"}` and the mixed scope lost its GCP version from
    # the candidate list.
    test "one store serves both shapes at once, each down its own path" do
      wrapped = TestKeyStore.provision!("merchant_7f3", 1)
      gcp = TestGcpKms.provision!("merchant_a19")

      TestKeyStore.provision!("merchant_b22", 2)
      mixed_gcp = TestGcpKms.provision!("merchant_b22")

      state = TestGcpKms.state()

      assert {:ok, [descriptor]} = KeyStore.decryption_keys(state, "merchant_7f3")
      assert descriptor.name == wrapped.name

      assert {:ok, [gcp_descriptor]} = KeyStore.decryption_keys(state, "merchant_a19")
      assert gcp_descriptor.name == gcp.name

      assert {:ok, [v2, v1]} = KeyStore.decryption_keys(state, "merchant_b22")
      assert v2.name == "t/#{ref(v2)}/v2"
      assert v1.name == mixed_gcp.name
    end

    # Sabotage: used `String.to_existing_atom/1` on the column. A row carrying
    # a value nobody has ever written as an atom raised `ArgumentError` from
    # inside a provider callback, which the vault has no arm for - a crash
    # where the contract already has a word.
    test "a shape the record does not publish is invalid_key_descriptor, not a raise" do
      TestKeyStore.provision!("merchant_7f3", 1, wrapping_shape: "vault_transit")

      assert {:error, {:invalid_key_descriptor, {:unknown_wrapping_shape, "vault_transit"}}} =
               KeyStore.decryption_keys(TestKeyStore.state(), "merchant_7f3")
    end

    # The `key_id` rules are read-side because each is conditional on the other
    # column, and a conditional constraint is not portable DDL. Neither arm
    # carries the id out: a key id is a resource name.
    test "a gcp row with no key_id is missing_key_id, and carries nothing" do
      TestKeyStore.provision!("merchant_7f3", 1, wrapping_shape: "gcp_kms_ciphertext")

      assert {:error, {:invalid_key_descriptor, :missing_key_id}} =
               KeyStore.decryption_keys(TestKeyStore.state(), "merchant_7f3")
    end

    test "an engine-message row carrying a key_id is unexpected_key_id" do
      TestKeyStore.provision!("merchant_7f3", 1, key_id: "k1")

      assert {:error, {:invalid_key_descriptor, :unexpected_key_id}} =
               KeyStore.decryption_keys(TestKeyStore.state(), "merchant_7f3")
    end
  end

  describe "a gcp_kms_ciphertext row, with the GCP branch configured" do
    # ADR-0005 Amendment A: the row is handed to `Encryptor.Provider.GcpKms`'s
    # public `decryption_keys/2` through a one-row store, and what comes back
    # is the provider's own descriptor. The comparison below is against the
    # provider asked directly about the same row, so the store adds nothing
    # and loses nothing on the way through.
    #
    # Sabotage: restored the unconditional `{:unsupported_wrapping_shape,
    # "gcp_kms_ciphertext"}` arm. Both callbacks answered that refusal and the
    # first `assert {:ok, ...}` went red.
    test "round-trips: both callbacks answer the key the provider minted" do
      provisioned = TestGcpKms.provision!("merchant_7f3")
      state = TestGcpKms.state()

      assert {:ok, [descriptor]} = KeyStore.decryption_keys(state, "merchant_7f3")
      assert {:ok, ^descriptor} = KeyStore.encryption_key(state, "merchant_7f3")

      assert descriptor.name == provisioned.name
      assert descriptor.namespace == provisioned.namespace
      assert descriptor.bits == 256

      {:ok, direct} =
        GcpKms.init(
          Keyword.merge(TestGcpKms.opts(),
            reference_subkey: TestKeyStore.reference_subkey(),
            store: fn _scope_ref -> {:ok, [provisioned]} end
          )
        )

      assert {:ok, [from_provider]} =
               GcpKms.decryption_keys(direct, "merchant_7f3")

      assert digest(descriptor) == digest(from_provider)
    end

    # The same key, end to end: a value written through a scoped vault whose
    # only stored copy of its key is a GCP KMS ciphertext reads back, and the
    # message names the key the row declares.
    test "a value written through the vault reads back under the GCP-wrapped key" do
      provisioned = TestGcpKms.provision!("merchant_7f3")
      plaintext = "the value in merchant_7f3's column"

      assert {:ok, ciphertext} =
               TestGcpKms.Scope.encrypt(plaintext,
                 key: "merchant_7f3",
                 encryption_context: @context
               )

      assert {:ok, ^plaintext} =
               TestGcpKms.Scope.decrypt(ciphertext,
                 key: "merchant_7f3",
                 encryption_context: @context
               )

      assert {:ok, info} = Message.describe(ciphertext)
      assert [%{key_name: written_under}] = info.encrypted_data_keys
      assert written_under == provisioned.name
    end

    # A GCP wrapping is bound to its row's `tenant_ref`, `version` and
    # `namespace` through the additional authenticated data, so a row filed
    # under another scope fails closed at `Decrypt`. The provider's public
    # answer is `{:key_unavailable, selector}`, which merges a refused
    # `Decrypt` with an unreachable service, and the store returns it
    # unrelabelled (ADR-0005 Amendment A5).
    #
    # Sabotage: translated every delegate failure into `{:invalid_key_descriptor,
    # :unwrap_failed}`. The first assertion went red on that term.
    #
    # Selectors of its own: the `UPDATE` writes a `{namespace, name}` that a
    # concurrent async test inserting `merchant_7f3` would also write, and two
    # sandboxed transactions contending on one unique key deadlocked.
    test "a row moved to another scope fails closed, in the provider's own term" do
      TestGcpKms.provision!("merchant_moved_from")
      {:ok, mine} = scope_ref("merchant_moved_to")
      {:ok, theirs} = scope_ref("merchant_moved_from")

      {1, _rows} =
        TestRepo.update_all(
          from(k in TestGcpKms.table(), where: k.tenant_ref == ^theirs),
          set: [tenant_ref: mine, name: "t/#{mine}/v1"]
        )

      state = TestGcpKms.state()

      assert {:error, {:key_unavailable, "merchant_moved_to"}} =
               KeyStore.decryption_keys(state, "merchant_moved_to")

      assert {:error, {:key_unavailable, "merchant_moved_to"}} =
               KeyStore.encryption_key(state, "merchant_moved_to")
    end

    # The "one bad row is not the whole store" rule holds for a GCP row as it
    # does for an engine message, because the dispatch is per row: with the
    # service unreachable, the scope's engine-message version still answers
    # reads, and a write - whose key is that newest row - is unaffected.
    #
    # Sabotage: matched the delegate's answer with `{:ok, [descriptor]} =`
    # instead of `with`, so its failure raised rather than returned. The first
    # assertion went red on a `MatchError` out of the callback - the whole
    # scope unreadable because one row's service was down.
    test "an unreachable service costs only the GCP rows" do
      TestGcpKms.provision!("merchant_7f3")
      TestKeyStore.provision!("merchant_7f3", 2)
      TestGcpKms.provision!("merchant_a19")

      state = TestGcpKms.state()
      TestGcpKms.outage(true)

      assert {:ok, [only]} = KeyStore.decryption_keys(state, "merchant_7f3")
      assert only.name == "t/#{ref(only)}/v2"
      assert {:ok, ^only} = KeyStore.encryption_key(state, "merchant_7f3")

      assert {:error, {:key_unavailable, "merchant_a19"}} =
               KeyStore.encryption_key(state, "merchant_a19")

      TestGcpKms.outage(false)

      assert {:ok, [_v2, _v1]} = KeyStore.decryption_keys(state, "merchant_7f3")
    end

    # The read-side `key_id` rule runs before the client is consulted, so a
    # configured store still answers the store's own term for it.
    #
    # Sabotage: moved the delegation clause above the `missing_key_id` clause.
    # The provider's own row check refused the `NULL` id first and the answer
    # became `{:invalid_key_descriptor, :invalid_row}`.
    test "a gcp row with no key_id is still missing_key_id" do
      TestKeyStore.provision!("merchant_7f3", 1, wrapping_shape: "gcp_kms_ciphertext")

      assert {:error, {:invalid_key_descriptor, :missing_key_id}} =
               KeyStore.decryption_keys(TestGcpKms.state(), "merchant_7f3")
    end
  end

  describe "a table created under 0.3.0, after the additive migration" do
    # The row this reads was written by a data migration *before* the columns
    # existed, which is the only arrangement that can show the backfill is
    # right. ADR-0005 decision 3: every row any adopter holds today was written
    # for a read path with no branch in it, so `"engine_message"` is not a guess
    # about history - it is the only value history can hold.
    #
    # Sabotage: backfilled `NULL` instead. The column is `null: false`, so the
    # migration itself failed on the way up - in the host's deploy, against a
    # populated table, which is the worst place to find out.
    test "a row written before the columns existed still resolves" do
      state = TestKeyStore.state(table: @legacy_table)

      assert {:ok, [descriptor]} = KeyStore.decryption_keys(state, @legacy_selector)
      assert descriptor.bits == 256
      assert {:ok, ^descriptor} = KeyStore.encryption_key(state, @legacy_selector)
    end

    test "and it was backfilled as an engine message with no key id" do
      assert [%{wrapping_shape: "engine_message", key_id: nil}] =
               TestRepo.all(
                 from(k in @legacy_table,
                   select: %{wrapping_shape: k.wrapping_shape, key_id: k.key_id}
                 )
               )
    end

    # Sabotage: left the backfill default in place by dropping the second
    # `alter`. This insert succeeded, silently, as an engine message - and
    # ADR-0005 decision 4 is that a forgotten shape must be a write-time error,
    # because this package writes no rows and every insert is the host's.
    test "the backfill default does not survive the migration" do
      assert_raise Postgrex.Error, fn ->
        TestRepo.insert_all(@legacy_table, [
          [
            tenant_ref: "whatever",
            version: 99,
            namespace: "n",
            name: "n/99",
            bits: 256,
            wrapped: <<0>>
          ]
        ])
      end
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
    # `agree/4` ahead of `engine_decrypt/4`), and on a `:scoped` vault
    # `tenant_ref` is derived from `:key` by the vault itself, so the read is
    # refused as `{:encryption_context_mismatch, "tenant_ref"}` with the
    # keyring never consulted. Both are authentication failures and both are
    # `:decrypt_failed` to a caller; which guard fires first is the vault's
    # business and not this provider's. The stale detail belongs to the
    # upstream record and was raised there rather than worked around here.
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
               TestKeyStore.Scope.encrypt(plaintext,
                 key: "merchant_7f3",
                 encryption_context: @context
               )

      assert {:ok, ^plaintext} =
               TestKeyStore.Scope.decrypt(ciphertext,
                 key: "merchant_7f3",
                 encryption_context: @context
               )

      assert {:error,
              %Error{
                reason: :decrypt_failed,
                operation: :decrypt,
                engine: {:encryption_context_mismatch, "tenant_ref"}
              }} =
               TestKeyStore.Scope.decrypt(ciphertext,
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
               TestKeyStore.Scope.encrypt("a value",
                 key: "merchant_7f3",
                 encryption_context: @context
               )

      assert {:error, %Error{reason: {:unknown_key, "merchant_none"}}} =
               TestKeyStore.Scope.decrypt(ciphertext,
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
               TestKeyStore.Scope.encrypt("written before the rotation",
                 key: "merchant_7f3",
                 encryption_context: @context
               )

      TestKeyStore.provision!("merchant_7f3", 2)

      assert {:ok, "written before the rotation"} =
               TestKeyStore.Scope.decrypt(old, key: "merchant_7f3", encryption_context: @context)
    end
  end

  # A row for this selector at this version whose `wrapped` will not open: a
  # real wrapping, produced for another partition, filed under this one's
  # reference and name. That is what a wrapping the root rotation has not
  # reached looks like from the read side - the bytes are intact and the
  # engine refuses them - and it is produced the same way the existing
  # `:unwrap_failed` test produces its own.
  defp corrupt!(selector, version) do
    {:ok, wrapped} =
      Encryptor.Envelope.provision(TestKeyStore.Root, "merchant_corrupt_source",
        reference_subkey: TestKeyStore.reference_subkey(),
        version: version
      )

    {:ok, ref} = scope_ref(selector)

    TestKeyStore.insert!(%{wrapped | scope_ref: ref, name: "t/#{ref}/v#{version}"})
  end

  # Ruins a row that is already there, which `corrupt!/2` cannot do: a value
  # has to be written under the version *before* its wrapping stops opening,
  # and that is the order a root rotation gone wrong happens in.
  defp break_wrapping!(selector, version) do
    {:ok, ref} = scope_ref(selector)

    {1, _rows} =
      TestRepo.update_all(
        from(k in KeyStore.default_table(),
          where: k.tenant_ref == ^ref and k.version == ^version
        ),
        set: [wrapped: :binary.copy(<<0>>, 64)]
      )

    :ok
  end

  defp ref(descriptor) do
    ["t", ref, _version] = String.split(descriptor.name, "/")

    ref
  end

  # A digest rather than the bytes: a scope master key is key-shaped, and a
  # `refute` that fails prints both sides of what it compared.
  defp digest(descriptor), do: :crypto.hash(:sha256, descriptor.material)

  defp scope_ref(selector) do
    Encryptor.Envelope.scope_ref(TestKeyStore.reference_subkey(), selector)
  end
end
