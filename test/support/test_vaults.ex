defmodule Encryptor.Ecto.TestVaults do
  @moduledoc """
  Real vaults the type tests encrypt and decrypt through.

  Nothing here is a stub. `use Encryptor.Vault` generates the same
  `encrypt/2` and `decrypt/2` a host calls, over `Encryptor.Provider.Static`
  and `Encryptor.Provider.Function` material, so the whole suite exercises the
  actual engine offline - no AWS dependency, no network. A mock vault would
  make every claim about the encryption context unfalsifiable, since the
  context is only checked where the message is authenticated.

  The worked domain is card processing: a per-merchant vault keyed by merchant
  reference, and a single-key application vault for fields that have no tenant.

  Key material arrives through `init/1` rather than through `use` options, the
  way the vault's own fixtures do it - `Encryptor.Vault.Config` refuses key
  material at `use` at compile time, and a fixture key is still key-shaped.
  """

  alias Encryptor.Key.Aes
  alias Encryptor.Vault.Reference

  # Constants rather than random bytes so a failing assertion is reproducible.
  # No test renders them.
  @merchant_7f3 :binary.copy(<<0x33>>, 32)
  @merchant_a19 :binary.copy(<<0x44>>, 32)
  @app :binary.copy(<<0x11>>, 32)
  @subkey :binary.copy(<<0x55>>, 32)

  # enc-ADR-0003 amendment A decision 3: one per-deployment value, not secret
  # but not compiled into a released artifact either, which is why it arrives
  # through `init/1` beside the provider rather than through `use` options.
  @derivation_salt :binary.copy(<<0x5A>>, 32)

  @merchants ["merchant_7f3", "merchant_a19"]

  # enc-ADR-0003 amendment B decision 4's parameter set, at the smallest one
  # the vault will accept: the memory floor is 32 MiB and one iteration is the
  # minimum, which keeps the suite's Argon2id hashes affordable without
  # weakening anything the tests assert. Nothing here is a production tuning
  # recommendation - what a host declares is a host's decision, and this
  # package neither supplies nor interprets it (ece-ADR-0003 amendment C
  # decision C5).
  @slow_hash [memory_kib: 32_768, iterations: 1, parallelism: 1]

  @doc "The Argon2id parameters the tenant vault declares."
  @spec slow_hash() :: keyword()
  def slow_hash, do: @slow_hash

  @doc "The per-deployment salt the blind index derives under."
  @spec derivation_salt() :: binary()
  def derivation_salt, do: @derivation_salt

  @doc "The material a merchant selector resolves to."
  @spec merchant_key(String.t()) :: binary()
  def merchant_key("merchant_7f3"), do: @merchant_7f3
  def merchant_key("merchant_a19"), do: @merchant_a19

  @doc "The subkey the tenant vault derives `tenant_ref` under."
  @spec reference_subkey() :: binary()
  def reference_subkey, do: @subkey

  @doc "The descriptor a merchant selector resolves to."
  @spec merchant_descriptor(String.t()) :: Aes.t()
  def merchant_descriptor(selector) do
    %Aes{
      namespace: "encryptor-tenant",
      name: "t/" <> Reference.derive(@subkey, selector) <> "/v1",
      material: merchant_key(selector),
      bits: 256
    }
  end

  @doc "A provider resolving a merchant selector to that merchant's own key."
  @spec merchant_provider() :: {module(), keyword()}
  def merchant_provider do
    {Encryptor.Provider.Function,
     encryption_key: fn
       selector when selector in @merchants -> {:ok, merchant_descriptor(selector)}
       selector -> {:error, {:unknown_key, selector}}
     end,
     decryption_keys: fn
       selector when selector in @merchants -> {:ok, [merchant_descriptor(selector)]}
       selector -> {:error, {:unknown_key, selector}}
     end}
  end

  @doc "The descriptor a merchant selector resolves to after a re-key."
  @spec rekeyed_descriptor(String.t()) :: Aes.t()
  def rekeyed_descriptor(selector) do
    %Aes{
      namespace: "encryptor-tenant",
      name: "t/" <> Reference.derive(@subkey, selector) <> "/v2",
      material: :binary.copy(<<0x66>>, 32),
      bits: 256
    }
  end

  @doc "A provider resolving a merchant selector to that merchant's re-keyed key."
  @spec rekeyed_provider() :: {module(), keyword()}
  def rekeyed_provider do
    {Encryptor.Provider.Function,
     encryption_key: fn
       selector when selector in @merchants -> {:ok, rekeyed_descriptor(selector)}
       selector -> {:error, {:unknown_key, selector}}
     end,
     decryption_keys: fn
       selector when selector in @merchants -> {:ok, [rekeyed_descriptor(selector)]}
       selector -> {:error, {:unknown_key, selector}}
     end}
  end

  @doc "The single key the application vault holds."
  @spec app_provider() :: {module(), keyword()}
  def app_provider do
    {Encryptor.Provider.Static, key: @app, namespace: "acme-app", name: "app/v1"}
  end

  defmodule Merchant do
    @moduledoc """
    The per-merchant vault: a `:tenant` profile requiring the column pair.

    `required_context: ["table", "column"]` is what makes the type's context
    composition testable rather than merely present - a type that forgot to
    supply the pair would be refused by the vault instead of silently writing
    a message bound to nothing.
    """

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :tenant,
      algorithm_suite_id: 0x0478,
      required_context: ["table", "column"],
      cache: false

    alias Encryptor.Ecto.TestVaults

    @doc "Layer 5: the provider and the reference subkey, both key material."
    def init(config) do
      {:ok,
       Keyword.merge(config,
         provider: TestVaults.merchant_provider(),
         reference_subkey: TestVaults.reference_subkey(),
         derivation_salt: TestVaults.derivation_salt(),
         slow_hash: TestVaults.slow_hash()
       )}
    end
  end

  defmodule MerchantRekeyed do
    @moduledoc """
    `Merchant`'s deployment after a re-key: same namespace, same tenant
    references, new key names over new material.

    ADR-0002's R3 names a rewrite whose "format, algorithm, library, or
    encryption context" changes, and this is the half of it that changes none
    of them: a message this vault wrote carries exactly the context, the
    tenant reference and the algorithm suite `Merchant` writes, and differs
    only in the wrapping key the header names. It exists so the probe can be
    held to that difference.
    """

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :tenant,
      algorithm_suite_id: 0x0478,
      required_context: ["table", "column"],
      cache: false

    alias Encryptor.Ecto.TestVaults

    @doc "Layer 5: the re-keyed provider, under `Merchant`'s own subkey."
    def init(config) do
      {:ok,
       Keyword.merge(config,
         provider: TestVaults.rekeyed_provider(),
         reference_subkey: TestVaults.reference_subkey(),
         derivation_salt: TestVaults.derivation_salt()
       )}
    end
  end

  defmodule MerchantStatic do
    @moduledoc """
    `Merchant` with a deployment-wide context pair of its own.

    `:static_encryption_context` is vault configuration rather than anything a
    field declares, so its pairs are on every message this vault writes and on
    none of the pairs `Encryptor.Ecto.Binary.declared_context/1` composes. That
    makes it the only fixture that can hold the migrator's probe to the *merge*
    of the two: a probe comparing the declaration alone would find a pair it
    did not expect on the target's own rows and rewrite every one of them,
    forever.
    """

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :tenant,
      algorithm_suite_id: 0x0478,
      required_context: ["table", "column"],
      static_encryption_context: %{"deployment" => "eu-west-1"},
      cache: false

    alias Encryptor.Ecto.TestVaults

    @doc "Layer 5: `Merchant`'s own provider and subkey."
    def init(config) do
      {:ok,
       Keyword.merge(config,
         provider: TestVaults.merchant_provider(),
         reference_subkey: TestVaults.reference_subkey(),
         derivation_salt: TestVaults.derivation_salt()
       )}
    end
  end

  defmodule MerchantSigned do
    @moduledoc """
    `Merchant` writing the other algorithm suite.

    The R3 dimension the header names in one integer. Everything else - the
    provider, the material, the key names, the subkey, the required pair - is
    `Merchant`'s, so a message from here differs from one of `Merchant`'s in
    the suite and in nothing the probe compares beside it.
    """

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :tenant,
      algorithm_suite_id: 0x0578,
      required_context: ["table", "column"],
      cache: false

    alias Encryptor.Ecto.TestVaults

    @doc "Layer 5: `Merchant`'s own provider and subkey, a different suite."
    def init(config) do
      {:ok,
       Keyword.merge(config,
         provider: TestVaults.merchant_provider(),
         reference_subkey: TestVaults.reference_subkey(),
         derivation_salt: TestVaults.derivation_salt()
       )}
    end
  end

  defmodule App do
    @moduledoc """
    The single-key vault a `tenant: :none` field points at.

    Acceptance amendment 3: a global field cannot ride a `:tenant`-profile
    vault with the pair omitted, so it names a `:single` one instead.

    It declares no `:slow_hash`, deliberately: ece-ADR-0003 amendment C's
    decision C7 refuses a `slow: true` index against exactly such a vault, and
    a refusal needs a vault that starts, encrypts and derives normally in
    every other respect to be a refusal about the declaration rather than
    about a broken fixture.
    """

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :single,
      algorithm_suite_id: 0x0478,
      required_context: ["table", "column"],
      cache: false

    alias Encryptor.Ecto.TestVaults

    @doc "Layer 5: the key material a config file must not hold."
    def init(config) do
      {:ok,
       Keyword.merge(config,
         provider: TestVaults.app_provider(),
         derivation_salt: TestVaults.derivation_salt()
       )}
    end
  end

  defmodule Unsalted do
    @moduledoc """
    A vault with no `:derivation_salt`, so the refusal arm has a subject.

    enc-ADR-0003 amendment A decision 3 makes the salt optional at start and
    required at derivation, precisely so that an existing vault keeps starting.
    This vault is what proves the second half: it starts, it encrypts, and it
    refuses to derive.
    """

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :single,
      algorithm_suite_id: 0x0478,
      cache: false

    alias Encryptor.Ecto.TestVaults

    @doc "Layer 5: the provider, and deliberately no salt."
    def init(config) do
      {:ok, Keyword.put(config, :provider, TestVaults.app_provider())}
    end
  end

  defmodule OtherDeployment do
    @moduledoc """
    The `App` vault's key material under a second deployment's salt.

    Amendment A's reason for salting the exported tree at all is that two
    deployments provisioned from the same key material must derive unrelated
    subkeys - a restored backup, a cloned staging environment. That claim is
    only testable with two vaults differing in nothing but the salt, so this
    is that vault.
    """

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :single,
      algorithm_suite_id: 0x0478,
      cache: false

    alias Encryptor.Ecto.TestVaults

    @doc "Layer 5: the same provider as `App`, under a different salt."
    def init(config) do
      {:ok,
       Keyword.merge(config,
         provider: TestVaults.app_provider(),
         derivation_salt: :binary.copy(<<0x5B>>, 32)
       )}
    end
  end

  defmodule Strict do
    @moduledoc """
    A vault requiring a context key this package never supplies.

    `"purpose"` is a canonical key that comes from vault configuration rather
    than from the type, so a field declared without it is exactly the host
    misconfiguration acceptance amendment 2 gives its own exception.
    """

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :single,
      algorithm_suite_id: 0x0478,
      required_context: ["table", "column", "purpose"],
      cache: false

    alias Encryptor.Ecto.TestVaults

    @doc "Layer 5: the key material a config file must not hold."
    def init(config) do
      {:ok, Keyword.put(config, :provider, TestVaults.app_provider())}
    end
  end

  defmodule Unstarted do
    @moduledoc "A vault module that is never started, so the not-started arm has a subject."

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :single,
      cache: false

    alias Encryptor.Ecto.TestVaults

    @doc "Layer 5: never reached - nothing starts this vault."
    def init(config) do
      {:ok, Keyword.put(config, :provider, TestVaults.app_provider())}
    end
  end
end
