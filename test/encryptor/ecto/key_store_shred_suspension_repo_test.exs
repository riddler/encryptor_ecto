defmodule Encryptor.Ecto.KeyStoreShredSuspensionRepoTest do
  @moduledoc """
  A whole-scope shred and the scope's suspension row.

  A scope suspended before it is shredded keeps a row in the suspension
  table, and that row holds the selector as the host wrote it. When the
  vault's suspension store is `Encryptor.Ecto.SuspensionStore` on the key
  store's own repo, `Encryptor.Ecto.KeyStore.shred/3` deletes that row in the
  transaction that deletes the scope's keys, so a dump taken afterwards holds
  neither. A single-version shred leaves the scope alive and its suspension
  in place; a store on another repo is not reached by the transaction and is
  left alone.

  Not async: the vault's suspension refresher is a process of its own, so the
  sandbox connection is shared with it.
  """

  use Encryptor.Ecto.RepoCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.KeyStore.Shred
  alias Encryptor.Ecto.SuspensionStore
  alias Encryptor.Ecto.TestKeyStore
  alias Encryptor.Error

  @context %{"table" => "cards", "column" => "pan"}

  defmodule SharedRepoScope do
    @moduledoc "A scoped vault whose suspension store shares the key store's repo."

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :scoped,
      required_context: ["table", "column"],
      cache: false,
      suspension_poll_interval: 50

    alias Encryptor.Ecto.KeyStore
    alias Encryptor.Ecto.SuspensionStore
    alias Encryptor.Ecto.TestKeyStore
    alias Encryptor.Ecto.TestRepo

    def init(config) do
      {:ok,
       Keyword.merge(config,
         provider: {KeyStore, TestKeyStore.provider_opts()},
         reference_subkey: TestKeyStore.reference_subkey(),
         suspension_store: {SuspensionStore, repo: TestRepo}
       )}
    end
  end

  defmodule OtherVault do
    @moduledoc "A second vault over the same suspension table, whose rows are its own."

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :scoped,
      required_context: ["table", "column"],
      cache: false,
      suspension_poll_interval: 50

    alias Encryptor.Ecto.KeyStore
    alias Encryptor.Ecto.SuspensionStore
    alias Encryptor.Ecto.TestKeyStore
    alias Encryptor.Ecto.TestRepo

    def init(config) do
      {:ok,
       Keyword.merge(config,
         provider: {KeyStore, TestKeyStore.provider_opts()},
         reference_subkey: TestKeyStore.reference_subkey(),
         suspension_store: {SuspensionStore, repo: TestRepo}
       )}
    end
  end

  defmodule OtherRepoScope do
    @moduledoc """
    A scoped vault whose suspension store names a repo other than the key
    store's. The shred's transaction cannot reach it.
    """

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :scoped,
      required_context: ["table", "column"],
      cache: false,
      suspension_poll_interval: 60_000

    alias Encryptor.Ecto.KeyStore
    alias Encryptor.Ecto.SuspensionStore
    alias Encryptor.Ecto.TestKeyStore

    def init(config) do
      {:ok,
       Keyword.merge(config,
         provider: {KeyStore, TestKeyStore.provider_opts()},
         reference_subkey: TestKeyStore.reference_subkey(),
         suspension_store: {SuspensionStore, repo: TestKeyStore.UnstartedRepo}
       )}
    end
  end

  setup do
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(id, [:encryptor, :suspension, :changed], &__MODULE__.forward/4, self())

    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "a whole-scope shred" do
    # Sabotage: made `forget_suspension/3`'s `:all` clause answer `:ok`
    # without the delete. The row survived the shred and the
    # `suspended(SharedRepoScope) == ["merchant_kept"]` assertion went red
    # on `["merchant_gone", "merchant_kept"]`.
    test "deletes the scope's suspension row and no other" do
      start_supervised!(SharedRepoScope)
      start_supervised!(OtherVault)
      TestKeyStore.provision!("merchant_gone", 1)
      TestKeyStore.provision!("merchant_gone", 2)
      TestKeyStore.provision!("merchant_kept", 1)

      assert :ok = Encryptor.Vault.suspend(SharedRepoScope, "merchant_gone")
      assert :ok = Encryptor.Vault.suspend(SharedRepoScope, "merchant_kept")
      assert :ok = Encryptor.Vault.suspend(OtherVault, "merchant_gone")

      assert {:ok, %Shred{procedure: :scope, versions: [1, 2], remaining: []}} =
               KeyStore.shred(SharedRepoScope, "merchant_gone", version: :all)

      assert suspended(SharedRepoScope) == ["merchant_kept"]
      assert suspended(OtherVault) == ["merchant_gone"]
    end

    # Once the row is gone the vault's next poll drops the scope from its
    # view, and a read of the shredded scope answers what enc-ADR-0005
    # decision 9 says a read after P3 answers.
    #
    # Sabotage: the same `forget_suspension/3` change. No poll changed the
    # set, `await_refresh/0` timed out, and the test went red there.
    test "after the next poll a read answers unknown_key, not the suspension" do
      start_supervised!(SharedRepoScope)
      await_refresh()
      selector = "merchant_suspended_then_shredded"
      TestKeyStore.provision!(selector, 1)
      {:ok, ciphertext} = encrypt(SharedRepoScope, selector)

      assert :ok = Encryptor.Vault.suspend(SharedRepoScope, selector)

      assert {:error, %Error{reason: {:key_unavailable, ^selector}}} =
               SharedRepoScope.decrypt(ciphertext, key: selector, encryption_context: @context)

      assert {:ok, %Shred{}} = KeyStore.shred(SharedRepoScope, selector, version: :all)
      await_refresh()

      assert {:error, %Error{reason: {:unknown_key, ^selector}}} =
               SharedRepoScope.decrypt(ciphertext, key: selector, encryption_context: @context)
    end

    # Sabotage: made `forget_suspension/3` delete every row of the vault
    # (`SuspensionStore.reinstate/2` replaced by a `delete_all` without the
    # selector condition). The bystander's row went and the assertion went
    # red on `[]`.
    test "of a scope never suspended leaves the record and the table as they were" do
      start_supervised!(SharedRepoScope)
      TestKeyStore.provision!("merchant_never_suspended", 1)
      TestKeyStore.provision!("merchant_bystander", 1)
      assert :ok = Encryptor.Vault.suspend(SharedRepoScope, "merchant_bystander")

      assert {:ok,
              %Shred{
                vault: SharedRepoScope,
                procedure: :scope,
                versions: [1],
                remaining: [],
                table: "encryptor_wrapped_keys",
                prefix: nil,
                drain: :waited
              }} = KeyStore.shred(SharedRepoScope, "merchant_never_suspended", version: :all)

      assert suspended(SharedRepoScope) == ["merchant_bystander"]
    end

    # The suspension delete runs inside the key delete's transaction, so a
    # failure there takes the key delete back with it. A trigger makes the
    # suspension row's delete fail after it has run; the sandbox's
    # transaction rolls the trigger back with the test.
    #
    # Sabotage: moved `forget_suspension/3` out of the transaction, after
    # `delete_versions/5` returned. The keys were gone when the suspension
    # delete raised, and `key_versions/1 == [1, 2]` went red on `[]`.
    test "a failed suspension delete rolls back the key delete with it" do
      start_supervised!(SharedRepoScope)
      selector = "merchant_trigger"
      TestKeyStore.provision!(selector, 1)
      TestKeyStore.provision!(selector, 2)
      assert :ok = Encryptor.Vault.suspend(SharedRepoScope, selector)
      refuse_suspension_delete!(selector)

      assert_raise Postgrex.Error, ~r/suspension row kept/, fn ->
        KeyStore.shred(SharedRepoScope, selector, version: :all)
      end

      assert key_versions(selector) == [1, 2]
      assert suspended(SharedRepoScope) == [selector]
    end
  end

  describe "what keeps the suspension row" do
    # P4 leaves the scope alive, so its suspension stands.
    #
    # Sabotage: made `forget_suspension/3` match any `which`. The single
    # version shred deleted the row and the assertion went red on `[]`.
    test "a single-version shred" do
      start_supervised!(SharedRepoScope)
      selector = "merchant_p4_suspended"
      TestKeyStore.provision!(selector, 1)
      TestKeyStore.provision!(selector, 2)
      assert :ok = Encryptor.Vault.suspend(SharedRepoScope, selector)

      assert {:ok, %Shred{procedure: :version, versions: [1], remaining: [2]}} =
               KeyStore.shred(SharedRepoScope, selector, version: 1)

      assert suspended(SharedRepoScope) == [selector]
    end

    # Sabotage: called `forget_suspension/3` in `shred/3` ahead of
    # `delete_versions/5`, outside the transaction. The refusal deleted no
    # key, the row went all the same, and the assertion went red on `[]`.
    test "a refused shred" do
      start_supervised!(SharedRepoScope)
      selector = "merchant_refused"
      TestKeyStore.provision!(selector, 1)
      assert :ok = Encryptor.Vault.suspend(SharedRepoScope, selector)

      assert {:error, {:current_version, 1}} =
               KeyStore.shred(SharedRepoScope, selector, version: 1)

      assert {:error, {:unknown_version, 7}} =
               KeyStore.shred(SharedRepoScope, selector, version: 7)

      assert suspended(SharedRepoScope) == [selector]
    end

    # A suspension store on another repo is outside the shred's
    # transaction, so the shred does not touch it: the host reinstates the
    # scope after the shred, as `shred/3`'s documentation says. The repo
    # here is never started, so any call that reached it would raise.
    #
    # Sabotage: dropped the repo match from `suspension_state/2`. The shred
    # called the unstarted repo inside its transaction, answered
    # `{:key_unavailable, selector}`, and the `{:ok, _}` match went red.
    test "a suspension store on another repo" do
      start_supervised!(OtherRepoScope)
      TestKeyStore.provision!("merchant_other_repo", 1)

      assert {:ok, %Shred{procedure: :scope, versions: [1]}} =
               KeyStore.shred(OtherRepoScope, "merchant_other_repo", version: :all)

      assert key_versions("merchant_other_repo") == []
    end
  end

  @doc false
  def forward(
        _event,
        _measurements,
        %{vault: SharedRepoScope, action: :refresh} = metadata,
        owner
      ) do
    send(owner, {:refreshed, metadata.outcome})
    :ok
  end

  def forward(_event, _measurements, _metadata, _owner), do: :ok

  defp await_refresh do
    assert_receive {:refreshed, :ok}, 2_000
  end

  defp encrypt(vault, selector),
    do: vault.encrypt("a value", key: selector, encryption_context: @context)

  defp suspended(vault) do
    {:ok, state} = SuspensionStore.init(vault, repo: TestRepo)
    {:ok, selectors} = SuspensionStore.list(state)
    Enum.sort(selectors)
  end

  defp key_versions(selector) do
    {:ok, ref} = Encryptor.Envelope.scope_ref(TestKeyStore.reference_subkey(), selector)

    TestRepo.all(
      from(k in KeyStore.default_table(),
        where: k.scope_ref == ^ref,
        order_by: k.version,
        select: k.version
      )
    )
  end

  # A row-level trigger that raises when the named selector's suspension row
  # is deleted, after the delete has run. Created inside the test's sandbox
  # transaction, so it is gone when the test ends.
  defp refuse_suspension_delete!(selector) do
    TestRepo.query!("""
    CREATE FUNCTION refuse_suspension_delete_for_test() RETURNS trigger AS $$
    BEGIN
      IF OLD.selector = '#{selector}' THEN
        RAISE EXCEPTION 'suspension row kept';
      END IF;
      RETURN OLD;
    END;
    $$ LANGUAGE plpgsql
    """)

    TestRepo.query!("""
    CREATE TRIGGER refuse_suspension_delete AFTER DELETE ON encryptor_suspensions
    FOR EACH ROW EXECUTE FUNCTION refuse_suspension_delete_for_test()
    """)
  end
end
