defmodule Encryptor.Ecto.SuspensionStoreRepoTest do
  @moduledoc """
  `Encryptor.Ecto.SuspensionStore` against a real table, first through its
  four callbacks and then under a running vault.

  The vault half is the point. enc-ADR-0010 puts the refresher, the per-node
  view and the failure mode in `encryptor`; what this store owns is returning
  the shapes that let them work, and the only way to show that is a vault
  reading this store. Not async: the refresher is a process of the vault's
  own, so the sandbox connection is shared with it.
  """

  use Encryptor.Ecto.RepoCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Encryptor.Ecto.SuspensionStore
  alias Encryptor.Ecto.TestKeyStore
  alias Encryptor.Error

  @context %{"table" => "cards", "column" => "pan"}

  defmodule SuspendedScope do
    @moduledoc "A scoped vault over the key store whose suspended set is this store's."

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

  defmodule UnmigratedScope do
    @moduledoc "The same vault, pointed at a suspension table that was never created."

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
         suspension_store: {SuspensionStore, repo: TestRepo, table: "never_migrated"}
       )}
    end
  end

  describe "init/2" do
    # Sabotage: dropped `known_options/1` from the `with`. `:poll_interval`
    # was accepted and ignored, and the first assertion went red on
    # `{:ok, _}` - a host that believed it had tuned the poll here had not.
    test "refuses every option it does not read" do
      assert {:error, {:unknown_options, [:poll_interval]}} =
               SuspensionStore.init(SuspendedScope, repo: TestRepo, poll_interval: 10)

      assert {:error, {:missing_config, [:suspension_store, :repo]}} =
               SuspensionStore.init(SuspendedScope, [])

      assert {:error, {:invalid_config, :repo, :not_a_module}} =
               SuspensionStore.init(SuspendedScope, repo: "TestRepo")

      assert {:error, {:invalid_config, :table, :invalid_name}} =
               SuspensionStore.init(SuspendedScope, repo: TestRepo, table: "drop table x")

      assert {:error, {:invalid_config, :prefix, :invalid_name}} =
               SuspensionStore.init(SuspendedScope, repo: TestRepo, prefix: "")
    end

    # Sabotage: changed the default table to `"suspensions"`. The state
    # comparison went red on the table.
    test "resolves the defaults, keyed by the vault" do
      assert {:ok, state} = SuspensionStore.init(SuspendedScope, repo: TestRepo)

      assert state == %{
               repo: TestRepo,
               vault: "Encryptor.Ecto.SuspensionStoreRepoTest.SuspendedScope",
               table: "encryptor_suspensions",
               prefix: nil
             }
    end
  end

  describe "the callbacks" do
    # Sabotage: dropped `on_conflict: :nothing` from the insert. The second
    # suspension raised a unique violation and the test went red on it.
    test "suspend is idempotent, reinstate removes, list answers the set" do
      state = state(SuspendedScope)

      assert :ok = SuspensionStore.suspend(state, "merchant_a")
      assert :ok = SuspensionStore.suspend(state, "merchant_a")
      assert :ok = SuspensionStore.suspend(state, "merchant_b")

      assert {:ok, selectors} = SuspensionStore.list(state)
      assert Enum.sort(selectors) == ["merchant_a", "merchant_b"]
      assert row_count() == 2

      assert :ok = SuspensionStore.reinstate(state, "merchant_a")
      assert :ok = SuspensionStore.reinstate(state, "merchant_a")
      assert :ok = SuspensionStore.reinstate(state, "merchant_never")

      assert {:ok, ["merchant_b"]} = SuspensionStore.list(state)
    end

    # Sabotage: dropped the `vault` condition from `list/1`'s query. The
    # second vault read the first vault's suspension and the test went red on
    # `{:ok, ["merchant_a"]}`.
    test "two vaults never share a set" do
      mine = state(SuspendedScope)
      theirs = state(UnmigratedScope, table: "encryptor_suspensions")

      assert :ok = SuspensionStore.suspend(mine, "merchant_a")

      assert {:ok, []} = SuspensionStore.list(theirs)
      assert :ok = SuspensionStore.reinstate(theirs, "merchant_a")
      assert {:ok, ["merchant_a"]} = SuspensionStore.list(mine)
    end

    # Sabotage: widened `suspend/2`'s guard to any term. `:default` reached
    # the string column and the insert raised `DBConnection.EncodeError`.
    test "a selector the column cannot hold is refused, and never reinstated in error" do
      state = state(SuspendedScope)

      assert {:error, {:unsupported_selector, :default}} =
               SuspensionStore.suspend(state, :default)

      assert {:error, {:unsupported_selector, ""}} = SuspensionStore.suspend(state, "")
      assert :ok = SuspensionStore.reinstate(state, :default)
      assert {:ok, []} = SuspensionStore.list(state)
    end
  end

  describe "under a running vault" do
    setup do
      id = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(id, [:encryptor, :suspension, :changed], &__MODULE__.forward/4, self())

      on_exit(fn -> :telemetry.detach(id) end)
    end

    # Sabotage: made `list/1` answer `{:ok, []}` always. The next poll
    # emptied the view, the scope was served, and a `{:key_unavailable, _}`
    # assertion went red.
    test "a suspension written through the vault is denied, and survives a restart" do
      TestKeyStore.provision!("merchant_suspended", 1)
      TestKeyStore.provision!("merchant_served", 1)
      start_supervised!(SuspendedScope)
      await_refresh()

      assert :ok = Encryptor.Vault.suspend(SuspendedScope, "merchant_suspended")
      assert row_count() == 1

      assert {:error, %Error{reason: {:key_unavailable, "merchant_suspended"}}} =
               encrypt(SuspendedScope, "merchant_suspended")

      stop_supervised!(SuspendedScope)
      start_supervised!(SuspendedScope)
      await_refresh()

      assert {:ok, _ciphertext} = encrypt(SuspendedScope, "merchant_served")

      assert {:error, %Error{reason: {:key_unavailable, "merchant_suspended"}}} =
               encrypt(SuspendedScope, "merchant_suspended")
    end

    # Another node's write is a row this node did not make. The refresher
    # reads it within one poll interval.
    #
    # Sabotage: made `list/1` select `s.vault` instead of `s.selector`. The
    # view filled with the vault's name, the scope was served, and the
    # assertion went red on `{:ok, _}`.
    test "a row another node wrote reaches this node's view on the next poll" do
      TestKeyStore.provision!("merchant_elsewhere", 1)
      start_supervised!(SuspendedScope)
      await_refresh()

      assert :ok = SuspensionStore.suspend(state(SuspendedScope), "merchant_elsewhere")
      await_refresh()

      assert {:error, %Error{reason: {:key_unavailable, "merchant_elsewhere"}}} =
               encrypt(SuspendedScope, "merchant_elsewhere")

      assert :ok = Encryptor.Vault.reinstate(SuspendedScope, "merchant_elsewhere")
      assert {:ok, _ciphertext} = encrypt(SuspendedScope, "merchant_elsewhere")
      assert row_count() == 0
    end

    # The store does not rescue: a missing table raises out of the callback,
    # and the vault reports it as a failed write with the exception kept.
    #
    # Sabotage: wrapped `suspend/2`'s insert in a rescue answering
    # `{:error, :database}`. The `:engine` match went red.
    test "a table that was never migrated fails the write loudly and changes nothing" do
      start_supervised!(UnmigratedScope)

      assert {:error,
              %Error{
                reason: {:suspension_store_unavailable, SuspensionStore},
                engine: %{__struct__: Postgrex.Error, postgres: %{code: :undefined_table}}
              }} = Encryptor.Vault.suspend(UnmigratedScope, "merchant_x")
    end
  end

  @doc false
  def forward(_event, _measurements, %{vault: SuspendedScope, action: :refresh} = metadata, owner) do
    send(owner, {:refreshed, metadata.outcome})
    :ok
  end

  def forward(_event, _measurements, _metadata, _owner), do: :ok

  # The first refresh after a start always reports, because it loads the
  # view; a later one reports only when the set changed.
  defp await_refresh do
    assert_receive {:refreshed, :ok}, 2_000
  end

  defp encrypt(vault, selector),
    do: vault.encrypt("a value", key: selector, encryption_context: @context)

  defp state(vault, opts \\ []) do
    {:ok, state} = SuspensionStore.init(vault, Keyword.merge([repo: TestRepo], opts))
    state
  end

  defp row_count do
    TestRepo.one(from(s in SuspensionStore.default_table(), select: count()))
  end
end
