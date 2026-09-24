defmodule Encryptor.Ecto.KeyStoreShredRepoTest do
  @moduledoc """
  `Encryptor.Ecto.KeyStore.shred/3` against real rows, a real vault and a
  real engine.

  The acceptance property is `encryptor`'s enc-ADR-0005 decision 9 made
  executable: after P3 a read through the vault fails
  `{:unknown_key, selector}`, and after P4 a value written under the retired
  version fails `:decrypt_failed` while the scope's other versions still
  serve. Both answers come from the vault, not from the store, which is the
  only place a host ever sees them.
  """

  use Encryptor.Ecto.RepoCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.KeyStore.Shred
  alias Encryptor.Ecto.TestKeyStore
  alias Encryptor.Ecto.TestVaults
  alias Encryptor.Error

  @context %{"table" => "cards", "column" => "pan"}

  defmodule CachedScope do
    @moduledoc """
    A scoped vault over the key store with a one-second materials cache, so
    the drain has something to wait for.
    """

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :scoped,
      algorithm_suite_id: 0x0478,
      required_context: ["table", "column"],
      cache: [max_age: 1]

    alias Encryptor.Ecto.KeyStore
    alias Encryptor.Ecto.TestKeyStore

    def init(config) do
      {:ok,
       Keyword.merge(config,
         provider: {KeyStore, TestKeyStore.provider_opts()},
         reference_subkey: TestKeyStore.reference_subkey()
       )}
    end
  end

  defmodule UnreachableScope do
    @moduledoc "A scoped vault whose key store's repo is never started."

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :scoped,
      required_context: ["table", "column"],
      cache: false

    alias Encryptor.Ecto.KeyStore
    alias Encryptor.Ecto.TestKeyStore

    def init(config) do
      {:ok,
       Keyword.merge(config,
         provider: {KeyStore, TestKeyStore.provider_opts(repo: TestKeyStore.UnstartedRepo)},
         reference_subkey: TestKeyStore.reference_subkey()
       )}
    end
  end

  describe "P3, version: :all" do
    # Sabotage: made `doomed/3`'s `:all` clause keep the newest version
    # (`{:ok, Enum.drop(live, -1), [List.last(live)]}`). Version 2 survived
    # and the record's `versions: [1, 2]` match went red on `[1]`.
    test "deletes every version, and a read then fails unknown_key" do
      selector = "merchant_p3"
      TestKeyStore.provision!(selector, 1)
      TestKeyStore.provision!(selector, 2)
      ciphertext = encrypt!(selector)

      assert {:ok, %Shred{} = shred} =
               KeyStore.shred(TestKeyStore.Scope, selector, version: :all)

      assert %Shred{
               vault: TestKeyStore.Scope,
               procedure: :scope,
               versions: [1, 2],
               remaining: [],
               table: "encryptor_wrapped_keys",
               prefix: nil,
               drain: :waited
             } = shred

      assert shred.scope_ref == scope_ref(selector)
      assert rows(selector) == []

      assert {:error, %Error{reason: {:unknown_key, ^selector}}} =
               TestKeyStore.Scope.decrypt(ciphertext, key: selector, encryption_context: @context)

      assert {:error, %Error{reason: {:unknown_key, ^selector}}} =
               TestKeyStore.Scope.encrypt("x", key: selector, encryption_context: @context)
    end

    # Sabotage: dropped the `tenant_ref` condition from the delete. It
    # matched both scopes' rows, the `{^count, _}` match raised on `{2, nil}`,
    # and the transaction rolled back rather than take the neighbour.
    test "leaves every other scope's rows alone" do
      TestKeyStore.provision!("merchant_p3_gone", 1)
      TestKeyStore.provision!("merchant_p3_kept", 1)
      kept = encrypt!("merchant_p3_kept")

      assert {:ok, _shred} = KeyStore.shred(TestKeyStore.Scope, "merchant_p3_gone", version: :all)

      assert {:ok, "a value"} =
               TestKeyStore.Scope.decrypt(kept,
                 key: "merchant_p3_kept",
                 encryption_context: @context
               )
    end
  end

  describe "P4, version: n" do
    # Sabotage: deleted the newest row instead of the named one
    # (`{:ok, [List.last(live)], ...}` in `doomed/3`'s version clause).
    # Version 2 was deleted, and the record match went red on `[2]`.
    test "deletes one version; its values fail decrypt_failed and the rest still serve" do
      selector = "merchant_p4"
      TestKeyStore.provision!(selector, 1)
      old = encrypt!(selector)
      TestKeyStore.provision!(selector, 2)
      new = encrypt!(selector)

      assert {:ok, %Shred{procedure: :version, versions: [1], remaining: [2]}} =
               KeyStore.shred(TestKeyStore.Scope, selector, version: 1)

      assert rows(selector) == [2]

      assert {:error, %Error{reason: :decrypt_failed}} =
               TestKeyStore.Scope.decrypt(old, key: selector, encryption_context: @context)

      assert {:ok, "a value"} =
               TestKeyStore.Scope.decrypt(new, key: selector, encryption_context: @context)
    end

    # Sabotage: removed the `{:current_version, _}` arm of `doomed/3`. The
    # newest row was deleted, the refusal assertion went red on `{:ok, _}`,
    # and version 1 became the scope's current key again.
    test "refuses the newest version, and deletes nothing" do
      selector = "merchant_p4_newest"
      TestKeyStore.provision!(selector, 1)
      TestKeyStore.provision!(selector, 2)

      assert {:error, {:current_version, 2}} =
               KeyStore.shred(TestKeyStore.Scope, selector, version: 2)

      assert rows(selector) == [1, 2]
    end

    # Sabotage: the same removal as above; this refusal went red on `{:ok, _}`.
    test "refuses the only version the same way, which is P3's to take" do
      TestKeyStore.provision!("merchant_p4_only", 1)

      assert {:error, {:current_version, 1}} =
               KeyStore.shred(TestKeyStore.Scope, "merchant_p4_only", version: 1)

      assert rows("merchant_p4_only") == [1]
    end

    # Sabotage: removed the `{:unknown_version, _}` arm. The delete then
    # matched zero rows, the `{^count, _}` match raised, and the test went
    # red on a `MatchError` rather than a refusal.
    test "refuses a version the scope does not have" do
      TestKeyStore.provision!("merchant_p4_missing", 1)
      TestKeyStore.provision!("merchant_p4_missing", 2)

      assert {:error, {:unknown_version, 7}} =
               KeyStore.shred(TestKeyStore.Scope, "merchant_p4_missing", version: 7)

      assert rows("merchant_p4_missing") == [1, 2]
    end
  end

  describe "refusals" do
    # Sabotage: made `doomed/3` answer `{:ok, [], []}` for a scope with no
    # rows. The shred reported success for a scope that was never there, and
    # the assertion went red on `{:ok, %Shred{versions: []}}`.
    test "a scope with no rows, or no scope reference, is unknown_key" do
      assert {:error, {:unknown_key, "merchant_none"}} =
               KeyStore.shred(TestKeyStore.Scope, "merchant_none", version: :all)

      assert {:error, {:unknown_key, :default}} =
               KeyStore.shred(TestKeyStore.Scope, :default, version: :all)
    end

    # Sabotage: dropped `key_store_state/1`'s refusal clause and read
    # `provider_state` from any vault. The static vault's state reached
    # `scope_ref/2` and the test went red on a `KeyError`.
    test "a vault whose provider is not the key store is refused" do
      assert {:error, {:not_a_key_store_vault, TestVaults.Merchant}} =
               KeyStore.shred(TestVaults.Merchant, "merchant_7f3", version: :all)
    end

    # Sabotage: replaced `Vault.config/1` with a fabricated configuration.
    # The unstarted vault was refused as not a key-store vault instead, and
    # the match on `{:vault_not_started, _}` went red.
    test "a vault that is not started answers the vault's own error" do
      assert {:error, %Error{reason: {:vault_not_started, TestVaults.Unstarted}}} =
               KeyStore.shred(TestVaults.Unstarted, "merchant_7f3", version: :all)
    end

    # Sabotage: removed the `:version` requirement so a missing option read
    # as `:all`. A call that named no version shredded the whole scope, and
    # the first assertion went red on `{:ok, _}`.
    test "the options are checked before anything is read" do
      TestKeyStore.provision!("merchant_opts", 1)

      assert {:error, {:missing_option, :version}} =
               KeyStore.shred(TestKeyStore.Scope, "merchant_opts", [])

      for bad <- [0, -1, "1", :newest] do
        assert {:error, {:invalid_option, :version}} =
                 KeyStore.shred(TestKeyStore.Scope, "merchant_opts", version: bad)
      end

      assert {:error, {:invalid_option, :drain}} =
               KeyStore.shred(TestKeyStore.Scope, "merchant_opts", version: :all, drain: :later)

      assert {:error, {:unknown_options, [:force]}} =
               KeyStore.shred(TestKeyStore.Scope, "merchant_opts", version: :all, force: true)

      assert rows("merchant_opts") == [1]
    end

    # Sabotage: made `delete_versions/4`'s rescue re-raise every exception.
    # The unstarted repo's `RuntimeError` raised out of the call and the test
    # went red on it.
    test "a store that cannot be asked is key_unavailable" do
      start_supervised!(UnreachableScope)

      assert {:error, {:key_unavailable, "merchant_7f3"}} =
               KeyStore.shred(UnreachableScope, "merchant_7f3", version: :all)
    end
  end

  describe "the drain" do
    # The cache is why the drain exists. After P4 the vault still resolves the
    # scope - its other versions are live - so a value written under the
    # retired version is served out of cached materials until `max_age`
    # passes, exactly as enc-ADR-0005's P4 step 2 warns.
    #
    # Sabotage: made `drain_seconds/1` answer 0 for every vault. The call
    # returned at once and the elapsed-time assertion went red on 1 ms.
    test "drain: :wait returns only after the cache's max_age, and the read then fails" do
      start_supervised!(CachedScope)
      selector = "merchant_drain_wait"
      old = cached_retire_setup!(selector)

      started = System.monotonic_time(:millisecond)
      assert {:ok, shred} = KeyStore.shred(CachedScope, selector, version: 1)
      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed >= 1_000
      assert shred.drain == :waited
      assert DateTime.diff(shred.drained_at, shred.deleted_at, :millisecond) == 1_000

      assert {:error, %Error{reason: :decrypt_failed}} =
               CachedScope.decrypt(old, key: selector, encryption_context: @context)
    end

    # Sabotage: made `drain: :skip` wait as well. The call slept out
    # `max_age` and the cached read went red on `:decrypt_failed`.
    test "drain: :skip returns at once, and the cache still serves until drained_at" do
      start_supervised!(CachedScope)
      selector = "merchant_drain_skip"
      old = cached_retire_setup!(selector)

      assert {:ok, shred} = KeyStore.shred(CachedScope, selector, version: 1, drain: :skip)

      assert shred.drain == :skipped
      assert DateTime.diff(shred.drained_at, shred.deleted_at, :millisecond) == 1_000

      assert {:ok, "a value"} =
               CachedScope.decrypt(old, key: selector, encryption_context: @context)
    end

    # encryptor 0.5.0 asks the provider before it consults the materials
    # cache, so after P3 the provider's `{:unknown_key, _}` is the answer at
    # once, warm cache or not. The drain is still taken: enc-ADR-0005's P3
    # makes it a step, and ADR-0007 decision 3 keeps it.
    test "after P3 a warm cache does not serve the scope, even with the drain skipped" do
      start_supervised!(CachedScope)
      selector = "merchant_drain_p3"
      TestKeyStore.provision!(selector, 1)
      ciphertext = cached_round_trip!(selector)

      assert {:ok, _shred} = KeyStore.shred(CachedScope, selector, version: :all, drain: :skip)

      assert {:error, %Error{reason: {:unknown_key, ^selector}}} =
               CachedScope.decrypt(ciphertext, key: selector, encryption_context: @context)
    end

    # Sabotage: made `drain_seconds/1` answer 1 for `cache: false`. The
    # timestamps went red one second apart.
    test "a vault with no cache is drained when the delete commits" do
      TestKeyStore.provision!("merchant_drain_none", 1)

      assert {:ok, shred} =
               KeyStore.shred(TestKeyStore.Scope, "merchant_drain_none", version: :all)

      assert shred.drained_at == shred.deleted_at
    end
  end

  describe "telemetry" do
    setup do
      id = {__MODULE__, make_ref()}
      :ok = :telemetry.attach(id, [:encryptor_ecto, :shred], &__MODULE__.forward/4, self())
      on_exit(fn -> :telemetry.detach(id) end)
    end

    # Sabotage: added `scope_ref: ref` to the event's metadata. The literal
    # key list below went red on the extra member.
    test "one event per shred, with a closed metadata set and no scope" do
      TestKeyStore.provision!("merchant_event", 1)
      TestKeyStore.provision!("merchant_event", 2)
      TestKeyStore.provision!("merchant_event", 3)

      assert {:ok, _shred} = KeyStore.shred(TestKeyStore.Scope, "merchant_event", version: 1)
      assert {:ok, _shred} = KeyStore.shred(TestKeyStore.Scope, "merchant_event", version: :all)

      assert_received {:shred, %{count: 1}, first}
      assert_received {:shred, %{count: 2}, second}

      assert Enum.sort(Map.keys(first)) == [:procedure, :table, :vault]

      assert first == %{
               vault: TestKeyStore.Scope,
               procedure: :version,
               table: "encryptor_wrapped_keys"
             }

      assert second.procedure == :scope
    end

    # Sabotage: emitted the event at the top of `shred/3`, before any
    # refusal. The `refute_received` went red on the stray event.
    test "a refused shred emits nothing" do
      assert {:error, _reason} =
               KeyStore.shred(TestKeyStore.Scope, "merchant_no_event", version: :all)

      refute_received {:shred, _measurements, _metadata}
    end
  end

  @doc false
  def forward(_event, measurements, metadata, owner) do
    if self() == owner, do: send(owner, {:shred, measurements, metadata})
    :ok
  end

  defp encrypt!(selector) do
    {:ok, ciphertext} =
      TestKeyStore.Scope.encrypt("a value", key: selector, encryption_context: @context)

    ciphertext
  end

  # Writes a value under version 1, mints version 2, and reads the old value
  # once, so the cached vault holds its materials when version 1 is retired.
  defp cached_retire_setup!(selector) do
    TestKeyStore.provision!(selector, 1)
    old = cached_round_trip!(selector)
    TestKeyStore.provision!(selector, 2)

    {:ok, "a value"} = CachedScope.decrypt(old, key: selector, encryption_context: @context)

    old
  end

  # Encrypts and decrypts once, so the cached vault holds materials for the
  # scope when the shred runs.
  defp cached_round_trip!(selector) do
    {:ok, ciphertext} =
      CachedScope.encrypt("a value", key: selector, encryption_context: @context)

    {:ok, "a value"} =
      CachedScope.decrypt(ciphertext, key: selector, encryption_context: @context)

    ciphertext
  end

  defp scope_ref(selector) do
    {:ok, ref} = Encryptor.Envelope.scope_ref(TestKeyStore.reference_subkey(), selector)
    ref
  end

  defp rows(selector) do
    ref = scope_ref(selector)

    TestRepo.all(
      from(k in KeyStore.default_table(),
        where: k.tenant_ref == ^ref,
        order_by: [asc: k.version],
        select: k.version
      )
    )
  end
end
