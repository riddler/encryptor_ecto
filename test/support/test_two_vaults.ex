defmodule Encryptor.Ecto.TestTwoVaults do
  @moduledoc """
  The two-vaults guide's host, compiled and run.

  `docs/guides/two-vaults-customer-and-agreement.md` shows a generic SaaS
  host - a catalog service for libraries - that runs two scoped vaults: one
  whose scope is the customer (the library), for platform data and
  credentials, and one whose scope is a data agreement, for the loan records
  a library shares under that agreement. Every module below is one of the
  guide's code blocks with these literal substitutions and nothing else:

    * `alias Library.Repo` is `alias Encryptor.Ecto.TestRepo, as: Repo`, and
      any other `Library.Repo` is `Encryptor.Ecto.TestRepo`;
    * every other `Library.` prefix is `Encryptor.Ecto.TestTwoVaults.`;
    * the `:library` application is `:encryptor_ecto`.

  `Encryptor.Ecto.TwoVaultsGuideTest` holds the two to that: it reads the
  guide, applies the same substitutions, and asserts every `defmodule` block
  appears in this file verbatim once the moduledocs below are set aside. A
  guide block that no longer compiles, or one this file stopped matching, is
  a red test rather than a stale page.

  Nothing in `lib/` names any of this.
  """
end

defmodule Encryptor.Ecto.TestTwoVaults.Keys do
  @moduledoc """
  The guide's key-material module: the root, both subkeys, provisioning into
  either key table, and the agreement shred.
  """

  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.TestRepo, as: Repo
  alias Encryptor.Envelope

  @agreement_table "agreement_keys"

  def root_key do
    :encryptor_ecto
    |> Application.fetch_env!(:root_key_base64)
    |> Base.decode64!()
  end

  def wrapping_subkey, do: Envelope.root_subkey(root_key(), "root-wrap")
  def reference_subkey, do: Envelope.root_subkey(root_key(), "tenant-ref")
  def agreement_table, do: @agreement_table

  def provision(:customer, customer_id),
    do: provision(KeyStore.default_table(), "library-customer", customer_id)

  def provision(:agreement, agreement_id),
    do: provision(@agreement_table, "library-agreement", agreement_id)

  defp provision(table, namespace, selector) do
    with {:ok, wrapped} <-
           Envelope.provision(Encryptor.Ecto.TestTwoVaults.RootVault, selector,
             reference_subkey: reference_subkey(),
             namespace: namespace,
             version: 1
           ) do
      {1, _rows} =
        Repo.insert_all(table, [
          [
            tenant_ref: wrapped.scope_ref,
            version: wrapped.version,
            namespace: wrapped.namespace,
            name: wrapped.name,
            bits: wrapped.bits,
            wrapped: wrapped.wrapped,
            wrapping_shape: "engine_message"
          ]
        ])

      :ok
    end
  end

  def shred_agreement(agreement_id, opts \\ []) do
    KeyStore.shred(
      Encryptor.Ecto.TestTwoVaults.AgreementVault,
      agreement_id,
      Keyword.put(opts, :version, :all)
    )
  end
end

defmodule Encryptor.Ecto.TestTwoVaults.RootVault do
  @moduledoc "The guide's root vault: the wrappings in both key tables are its messages."

  use Encryptor.Vault, otp_app: :encryptor_ecto, context_profile: :single, cache: false

  alias Encryptor.Ecto.TestTwoVaults.Keys

  def init(config) do
    {:ok,
     Keyword.put(
       config,
       :provider,
       {Encryptor.Provider.Static,
        key: Keys.wrapping_subkey(), namespace: "library-root", name: "root/v1"}
     )}
  end
end

defmodule Encryptor.Ecto.TestTwoVaults.CustomerVault do
  @moduledoc "The guide's customer vault: scope = the customer, keys in the default table."

  use Encryptor.Vault,
    otp_app: :encryptor_ecto,
    context_profile: :scoped,
    required_context: ["table", "column"],
    cache: [max_age: 300]

  alias Encryptor.Ecto.TestTwoVaults.Keys

  def init(config) do
    {:ok,
     Keyword.merge(config,
       provider:
         {Encryptor.Ecto.KeyStore,
          repo: Encryptor.Ecto.TestRepo,
          root_vault: Encryptor.Ecto.TestTwoVaults.RootVault,
          reference_subkey: Keys.reference_subkey()},
       reference_subkey: Keys.reference_subkey()
     )}
  end
end

defmodule Encryptor.Ecto.TestTwoVaults.AgreementVault do
  @moduledoc "The guide's agreement vault: scope = the agreement, keys in their own table."

  use Encryptor.Vault,
    otp_app: :encryptor_ecto,
    context_profile: :scoped,
    required_context: ["table", "column"],
    cache: [max_age: 300]

  alias Encryptor.Ecto.TestTwoVaults.Keys

  def init(config) do
    {:ok,
     Keyword.merge(config,
       provider:
         {Encryptor.Ecto.KeyStore,
          repo: Encryptor.Ecto.TestRepo,
          root_vault: Encryptor.Ecto.TestTwoVaults.RootVault,
          reference_subkey: Keys.reference_subkey(),
          table: Keys.agreement_table()},
       reference_subkey: Keys.reference_subkey()
     )}
  end
end

defmodule Encryptor.Ecto.TestTwoVaults.AgreementScope do
  @moduledoc "The guide's agreement resolver: the agreement id the caller took off the row."

  @behaviour Encryptor.Ecto.ScopeContext

  @key {__MODULE__, :agreement_id}

  def with_agreement(agreement_id, fun) when is_binary(agreement_id) and is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, agreement_id)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @impl Encryptor.Ecto.ScopeContext
  def resolve(_operation, _params) do
    case Process.get(@key) do
      agreement_id when is_binary(agreement_id) -> {:ok, agreement_id}
      nil -> {:error, :no_agreement_in_scope}
    end
  end
end

defmodule Encryptor.Ecto.TestTwoVaults.Encrypted.CustomerBinary do
  @moduledoc "The guide's customer-scoped type: the built-in process resolver."

  use Encryptor.Ecto.Binary, vault: Encryptor.Ecto.TestTwoVaults.CustomerVault
end

defmodule Encryptor.Ecto.TestTwoVaults.Encrypted.AgreementString do
  @moduledoc "The guide's agreement-scoped type: the agreement resolver."

  use Encryptor.Ecto.String,
    vault: Encryptor.Ecto.TestTwoVaults.AgreementVault,
    scope: Encryptor.Ecto.TestTwoVaults.AgreementScope
end

defmodule Encryptor.Ecto.TestTwoVaults.Account do
  @moduledoc "The guide's customer-scoped schema."

  use Ecto.Schema

  schema "library_accounts" do
    field :customer_id, :string
    field :catalog_api_token, Encryptor.Ecto.TestTwoVaults.Encrypted.CustomerBinary
  end
end

defmodule Encryptor.Ecto.TestTwoVaults.SharedLoan do
  @moduledoc "The guide's agreement-scoped schema."

  use Ecto.Schema

  schema "shared_loans" do
    field :customer_id, :string
    field :agreement_id, :string
    field :patron_email, Encryptor.Ecto.TestTwoVaults.Encrypted.AgreementString
  end
end

defmodule Encryptor.Ecto.TestTwoVaults.Loans do
  @moduledoc "The guide's loan functions: every read and write names its agreement."

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Encryptor.Ecto.TestRepo, as: Repo
  alias Encryptor.Ecto.TestTwoVaults.AgreementScope
  alias Encryptor.Ecto.TestTwoVaults.SharedLoan

  def record(attrs) do
    %SharedLoan{}
    |> Changeset.cast(attrs, [:customer_id, :agreement_id, :patron_email])
    |> Changeset.validate_required([:customer_id, :agreement_id])
    |> insert_under_agreement()
  end

  defp insert_under_agreement(%Changeset{valid?: false} = changeset), do: {:error, changeset}

  defp insert_under_agreement(changeset) do
    agreement_id = Changeset.fetch_field!(changeset, :agreement_id)

    AgreementScope.with_agreement(agreement_id, fn ->
      Repo.insert(changeset)
    end)
  end

  def list(agreement_id) do
    AgreementScope.with_agreement(agreement_id, fn ->
      Repo.all(from(l in SharedLoan, where: l.agreement_id == ^agreement_id))
    end)
  end

  def forget(agreement_id) do
    {count, _rows} =
      Repo.delete_all(from(l in SharedLoan, where: l.agreement_id == ^agreement_id))

    {:ok, count}
  end
end
