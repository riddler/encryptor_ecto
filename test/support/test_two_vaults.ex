defmodule Encryptor.Ecto.TestTwoVaults do
  @moduledoc """
  The two-vaults guide's host, compiled and run.

  `docs/guides/two-vaults-long-and-short-lived-scopes.md` shows a host that
  runs two scoped vaults: one whose scope is the owner, which lives as long
  as the owner does, and one whose scope is a grant, which ends on its own
  while the owner stays. Every module below is one of the
  guide's code blocks with these literal substitutions and nothing else:

    * `alias MyApp.Repo` is `alias Encryptor.Ecto.TestRepo, as: Repo`, and
      any other `MyApp.Repo` is `Encryptor.Ecto.TestRepo`;
    * every other `MyApp.` prefix is `Encryptor.Ecto.TestTwoVaults.`;
    * the `:my_app` application is `:encryptor_ecto`.

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
  either key table, and the grant shred.
  """

  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.TestRepo, as: Repo
  alias Encryptor.Envelope

  @grant_table "grant_keys"

  def root_key do
    :encryptor_ecto
    |> Application.fetch_env!(:root_key_base64)
    |> Base.decode64!()
  end

  def wrapping_subkey, do: Envelope.root_subkey(root_key(), "root-wrap")
  def reference_subkey, do: Envelope.root_subkey(root_key(), "scope-ref")
  def grant_table, do: @grant_table

  def provision(:owner, owner_id),
    do: provision(KeyStore.default_table(), "my-app-owner", owner_id)

  def provision(:grant, grant_id),
    do: provision(@grant_table, "my-app-grant", grant_id)

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
            scope_ref: wrapped.scope_ref,
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

  def shred_grant(grant_id, opts \\ []) do
    KeyStore.shred(
      Encryptor.Ecto.TestTwoVaults.GrantVault,
      grant_id,
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
        key: Keys.wrapping_subkey(), namespace: "my-app-root", name: "root/v1"}
     )}
  end
end

defmodule Encryptor.Ecto.TestTwoVaults.OwnerVault do
  @moduledoc "The guide's owner vault: scope = the owner, keys in the default table."

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

defmodule Encryptor.Ecto.TestTwoVaults.GrantVault do
  @moduledoc "The guide's grant vault: scope = the grant, keys in their own table."

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
          table: Keys.grant_table()},
       reference_subkey: Keys.reference_subkey()
     )}
  end
end

defmodule Encryptor.Ecto.TestTwoVaults.GrantScope do
  @moduledoc "The guide's grant resolver: the grant id the caller took off the row."

  @behaviour Encryptor.Ecto.ScopeContext

  @key {__MODULE__, :grant_id}

  def with_grant(grant_id, fun) when is_binary(grant_id) and is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, grant_id)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @impl Encryptor.Ecto.ScopeContext
  def resolve(_operation, _params) do
    case Process.get(@key) do
      grant_id when is_binary(grant_id) -> {:ok, grant_id}
      nil -> {:error, :no_grant_in_scope}
    end
  end
end

defmodule Encryptor.Ecto.TestTwoVaults.Encrypted.OwnerBinary do
  @moduledoc "The guide's owner-scoped type: the built-in process resolver."

  use Encryptor.Ecto.Binary, vault: Encryptor.Ecto.TestTwoVaults.OwnerVault
end

defmodule Encryptor.Ecto.TestTwoVaults.Encrypted.GrantString do
  @moduledoc "The guide's grant-scoped type: the grant resolver."

  use Encryptor.Ecto.String,
    vault: Encryptor.Ecto.TestTwoVaults.GrantVault,
    scope: Encryptor.Ecto.TestTwoVaults.GrantScope
end

defmodule Encryptor.Ecto.TestTwoVaults.OwnerRecord do
  @moduledoc "The guide's owner-scoped schema."

  use Ecto.Schema

  schema "owner_records" do
    field :owner_id, :string
    field :secret_token, Encryptor.Ecto.TestTwoVaults.Encrypted.OwnerBinary
  end
end

defmodule Encryptor.Ecto.TestTwoVaults.GrantRecord do
  @moduledoc "The guide's grant-scoped schema."

  use Ecto.Schema

  schema "grant_records" do
    field :owner_id, :string
    field :grant_id, :string
    field :note, Encryptor.Ecto.TestTwoVaults.Encrypted.GrantString
  end
end

defmodule Encryptor.Ecto.TestTwoVaults.GrantRecords do
  @moduledoc "The guide's record functions: every read and write names its grant."

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Encryptor.Ecto.TestRepo, as: Repo
  alias Encryptor.Ecto.TestTwoVaults.GrantRecord
  alias Encryptor.Ecto.TestTwoVaults.GrantScope

  def record(attrs) do
    %GrantRecord{}
    |> Changeset.cast(attrs, [:owner_id, :grant_id, :note])
    |> Changeset.validate_required([:owner_id, :grant_id])
    |> insert_under_grant()
  end

  defp insert_under_grant(%Changeset{valid?: false} = changeset), do: {:error, changeset}

  defp insert_under_grant(changeset) do
    grant_id = Changeset.fetch_field!(changeset, :grant_id)

    GrantScope.with_grant(grant_id, fn ->
      Repo.insert(changeset)
    end)
  end

  def list(grant_id) do
    GrantScope.with_grant(grant_id, fn ->
      Repo.all(from(l in GrantRecord, where: l.grant_id == ^grant_id))
    end)
  end

  def forget(grant_id) do
    {count, _rows} =
      Repo.delete_all(from(l in GrantRecord, where: l.grant_id == ^grant_id))

    {:ok, count}
  end
end
