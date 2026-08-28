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

  @merchants ["merchant_7f3", "merchant_a19"]

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
         reference_subkey: TestVaults.reference_subkey()
       )}
    end
  end

  defmodule App do
    @moduledoc """
    The single-key vault a `tenant: :none` field points at.

    Acceptance amendment 3: a global field cannot ride a `:tenant`-profile
    vault with the pair omitted, so it names a `:single` one instead.
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
      {:ok, Keyword.put(config, :provider, TestVaults.app_provider())}
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
