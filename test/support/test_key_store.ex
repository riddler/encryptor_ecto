defmodule Encryptor.Ecto.TestKeyStore do
  @moduledoc """
  The furniture `Encryptor.Ecto.KeyStore`'s tests resolve through.

  Nothing here is a stub. `Root` is a real single-key vault with a `Static`
  provider, `Tenant` is a real `:tenant` vault whose provider is the module
  under test, and the rows the tests read come from a real
  `Encryptor.Envelope.provision/3` against `Root`. A mock would make the
  acceptance property unfalsifiable: a cross-partition substitution fails
  because the engine authenticates the header, and nothing that skips the
  engine can show that.

  The two subkeys come from one root constant through
  `Encryptor.Envelope.root_subkey/2`, which is how a deployment holds them
  before its first root rotation. Constants rather than random bytes so a
  failing assertion is reproducible; no test renders them.
  """

  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.TestRepo
  alias Encryptor.Envelope
  alias Encryptor.Envelope.WrappedKey

  # A fixture root is still key-shaped, so it stays out of failure output.
  @root :binary.copy(<<0x6E>>, 32)

  @doc "The root key material both subkeys are expanded from."
  @spec root_key() :: binary()
  def root_key, do: @root

  @doc "The subkey the root vault holds as its `Static` provider material."
  @spec wrapping_subkey() :: binary()
  def wrapping_subkey, do: Envelope.root_subkey(@root, "root-wrap")

  @doc """
  The subkey `tenant_ref` derives under.

  The provider and the tenant vault are configured with the same value on
  purpose: a provider looking for a row under one reference while the vault
  writes a header claiming another would find nothing, for a reason no error
  message would explain.
  """
  @spec reference_subkey() :: binary()
  def reference_subkey, do: Envelope.root_subkey(@root, "tenant-ref")

  @doc "The provider options a host would write, with any of them overridden."
  @spec provider_opts(keyword()) :: keyword()
  def provider_opts(overrides \\ []) do
    Keyword.merge(
      [
        repo: TestRepo,
        root_vault: __MODULE__.Root,
        reference_subkey: reference_subkey()
      ],
      overrides
    )
  end

  @doc "Provider state, resolved the way the vault resolves it at start."
  @spec state(keyword()) :: term()
  def state(overrides \\ []) do
    {:ok, state} = KeyStore.init(provider_opts(overrides))

    state
  end

  @doc """
  Mints one version for a selector and stores it, returning the wrapping.

  This is the host's half of the seam: `Encryptor.Envelope.provision/3` is the
  vault's verb and the `INSERT` is this package's table. The provider under
  test performs neither.
  """
  @spec provision!(Encryptor.Envelope.selector(), pos_integer(), keyword()) :: WrappedKey.t()
  def provision!(selector, version \\ 1, overrides \\ []) do
    {:ok, wrapped} =
      Envelope.provision(__MODULE__.Root, selector,
        reference_subkey: reference_subkey(),
        version: version
      )

    insert!(wrapped, overrides)
  end

  @doc """
  Stores one wrapping, returning it.

  `:wrapping_shape` and `:key_id` are the row's, not the wrapping's - ADR-0005
  put them in columns rather than in `Encryptor.Envelope.WrappedKey` - so they
  arrive as overrides here. The defaults are what every row a host has today
  carries: an engine message, and no key id.

  `:table` and `:prefix` say where the row goes, and they are how a test
  reaches the 0.3.0-shaped table and the one in
  `Encryptor.Ecto.TestMigrationWrappedKeysPrefix`'s schema.
  """
  @spec insert!(WrappedKey.t(), keyword()) :: WrappedKey.t()
  def insert!(%WrappedKey{} = wrapped, overrides \\ []) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    table = Keyword.get(overrides, :table, KeyStore.default_table())

    {1, _rows} =
      TestRepo.insert_all(
        table,
        [
          [
            tenant_ref: wrapped.tenant_ref,
            version: wrapped.version,
            namespace: wrapped.namespace,
            name: wrapped.name,
            bits: wrapped.bits,
            wrapped: wrapped.wrapped,
            wrapping_shape: Keyword.get(overrides, :wrapping_shape, "engine_message"),
            key_id: Keyword.get(overrides, :key_id),
            inserted_at: now,
            updated_at: now
          ]
        ],
        Keyword.take(overrides, [:prefix])
      )

    wrapped
  end

  defmodule Root do
    @moduledoc """
    The root vault the wrappings are produced under.

    `Static` provider and `cache: false`, which is what
    `Encryptor.Envelope`'s acyclicity paragraph requires: a root vault
    configured with a store-backed provider would be a genuine cycle, and it
    would recurse or deadlock rather than fail cleanly.
    """

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :single,
      cache: false

    alias Encryptor.Ecto.TestKeyStore

    @doc "Layer 5: the wrapping subkey, which a config file must not hold."
    def init(config) do
      {:ok,
       Keyword.put(
         config,
         :provider,
         {Encryptor.Provider.Static,
          key: TestKeyStore.wrapping_subkey(), namespace: "encryptor-root", name: "root/v1"}
       )}
    end
  end

  defmodule Tenant do
    @moduledoc """
    A per-tenant vault whose keys come from the store.

    `cache: false` so every call re-resolves: the acceptance property is about
    what the provider and the engine do, and a cached partition would let a
    test pass on material an earlier test resolved.
    """

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :tenant,
      algorithm_suite_id: 0x0478,
      required_context: ["table", "column"],
      cache: false

    alias Encryptor.Ecto.KeyStore
    alias Encryptor.Ecto.TestKeyStore

    @doc "Layer 5: the provider and the reference subkey, both key material."
    def init(config) do
      {:ok,
       Keyword.merge(config,
         provider: {KeyStore, TestKeyStore.provider_opts()},
         reference_subkey: TestKeyStore.reference_subkey()
       )}
    end
  end

  defmodule UnstartedRepo do
    @moduledoc """
    A repository module that is never started, so `{:key_unavailable, _}` has a
    subject.

    `repo.all/1` raises when the repo is not started, which is the shape every
    "the store could not be asked" failure arrives in - a dead pool, an
    unreachable server, a supervisor that has not come up yet. Reproducing the
    arm this way needs no network partition and no killed container.
    """

    use Ecto.Repo,
      otp_app: :encryptor_ecto,
      adapter: Ecto.Adapters.Postgres
  end
end
