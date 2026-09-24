defmodule Encryptor.Ecto.TestRunbook do
  @moduledoc """
  A host walked through the migrate-from-cloak runbook, end to end.

  The domain is a generic SaaS host's third-party integrations: one secret
  column and two token columns per row, each row owned by a workspace, and
  every column written under **one legacy key** before the migration starts.

  Unlike `Encryptor.Ecto.TestLegacy`, the legacy side here really encrypts.
  The runbook's new step is about a legacy reader whose cipher lives in a
  process that reads its key from configuration when it starts - the shape a
  `cloak_ecto` vault has - and a fixture with no key and no process could not
  show what happens when that process was never started. The cipher is
  AES-256-GCM through `:crypto`, in an envelope laid out the way cloak's is (a
  reserved `0x01` byte, a length byte, a tag), so the census's four-byte
  prefix has something real to separate.

  Nothing in `lib/` names any of this. Every module is the host's half of the
  runbook, written the way the guide tells a host to write it.
  """

  defmodule LegacyVault do
    @moduledoc """
    The legacy vault: a process that reads its one key from configuration.

    The key is read from the application environment in `init/1` and kept in
    a named ETS table the process owns, which is where a `cloak_ecto` vault
    keeps its ciphers too. The consequence the runbook has to state follows
    from that: when the process was never started - a release task that
    starts only the repository - every read through it raises, because the
    table is not there.
    """

    use GenServer

    @table __MODULE__
    @header <<0x01, 4, "LGCY">>

    @doc "Starts the vault, reading its key from the application environment."
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl GenServer
    def init(_opts) do
      key = :encryptor_ecto |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(:key)
      table = :ets.new(@table, [:named_table, :protected, read_concurrency: true])
      true = :ets.insert(table, {:key, key})
      {:ok, table}
    end

    @doc "Encrypts under the one legacy key."
    @spec encrypt(binary()) :: binary()
    def encrypt(plaintext) when is_binary(plaintext) do
      iv = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @header, true)

      @header <> iv <> tag <> ciphertext
    end

    @doc "Decrypts under the one legacy key, and declines anything else."
    @spec decrypt(binary()) :: {:ok, binary()} | :error
    def decrypt(<<0x01, 4, "LGCY", iv::binary-12, tag::binary-16, ciphertext::binary>>) do
      case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @header, tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> :error
      end
    end

    def decrypt(_bytes), do: :error

    # Raises `ArgumentError` when the process never started: the table is
    # gone with the process that owned it.
    defp key, do: :ets.lookup_element(@table, :key, 2)
  end

  defmodule Legacy do
    @moduledoc "The host's legacy type modules: the ones step 3's `legacy:` names."

    defmodule Binary do
      @moduledoc "The legacy binary type, over the one legacy key."

      use Ecto.Type

      alias Encryptor.Ecto.TestRunbook.LegacyVault

      @impl Ecto.Type
      def type, do: :binary

      @impl Ecto.Type
      def cast(value) when is_binary(value), do: {:ok, value}
      def cast(_value), do: :error

      @impl Ecto.Type
      def dump(nil), do: {:ok, nil}
      def dump(value) when is_binary(value), do: {:ok, LegacyVault.encrypt(value)}
      def dump(_value), do: :error

      @impl Ecto.Type
      def load(nil), do: {:ok, nil}
      def load(bytes) when is_binary(bytes), do: LegacyVault.decrypt(bytes)
    end

    defmodule String do
      @moduledoc "The legacy text type: the binary one, for a string field."

      use Ecto.Type

      alias Encryptor.Ecto.TestRunbook.Legacy.Binary

      @impl Ecto.Type
      def type, do: :binary

      @impl Ecto.Type
      def cast(value) when is_binary(value), do: {:ok, value}
      def cast(_value), do: :error

      @impl Ecto.Type
      defdelegate dump(value), to: Binary

      @impl Ecto.Type
      defdelegate load(bytes), to: Binary
    end
  end

  defmodule Vault do
    @moduledoc """
    The new vault: per-workspace keys, read from configuration at start.

    Not started by `test/test_helper.exs`, deliberately: the runbook's release
    step is about what a pass does when nothing started it, and a vault the
    helper always starts could not show that.
    """

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :scoped,
      algorithm_suite_id: 0x0478,
      required_context: ["table", "column"],
      cache: false

    alias Encryptor.Key.Aes
    alias Encryptor.Vault.Reference

    @doc "Layer 5: the provider, subkey and salt, all read from configuration."
    def init(config) do
      keys = Application.fetch_env!(:encryptor_ecto, Encryptor.Ecto.TestRunbook.Keys)

      {:ok,
       Keyword.merge(config,
         provider: provider(Keyword.fetch!(keys, :workspaces), Keyword.fetch!(keys, :subkey)),
         reference_subkey: Keyword.fetch!(keys, :subkey),
         derivation_salt: Keyword.fetch!(keys, :derivation_salt)
       )}
    end

    defp provider(workspaces, subkey) do
      descriptor = fn selector ->
        case Map.fetch(workspaces, selector) do
          {:ok, material} ->
            {:ok,
             %Aes{
               namespace: "encryptor-tenant",
               name: "t/" <> Reference.derive(subkey, selector) <> "/v1",
               material: material,
               bits: 256
             }}

          :error ->
            {:error, {:unknown_key, selector}}
        end
      end

      {Encryptor.Provider.Function,
       encryption_key: descriptor,
       decryption_keys: fn selector ->
         with {:ok, key} <- descriptor.(selector), do: {:ok, [key]}
       end}
    end
  end

  defmodule Encrypted do
    @moduledoc "Step 3's type modules: the new vault, with `legacy:` set."

    defmodule Binary do
      @moduledoc "The secret column's type during the window."

      use Encryptor.Ecto.Binary,
        vault: Encryptor.Ecto.TestRunbook.Vault,
        legacy: Encryptor.Ecto.TestRunbook.Legacy.Binary
    end

    defmodule String do
      @moduledoc "The token columns' type during the window."

      use Encryptor.Ecto.String,
        vault: Encryptor.Ecto.TestRunbook.Vault,
        legacy: Encryptor.Ecto.TestRunbook.Legacy.String
    end
  end

  defmodule Final do
    @moduledoc "Step 8's type modules: `legacy:` gone."

    defmodule Binary do
      @moduledoc "The secret column's type once the window has closed."

      use Encryptor.Ecto.Binary, vault: Encryptor.Ecto.TestRunbook.Vault
    end

    defmodule String do
      @moduledoc "The token columns' type once the window has closed."

      use Encryptor.Ecto.String, vault: Encryptor.Ecto.TestRunbook.Vault
    end
  end

  defmodule LegacyIntegration do
    @moduledoc "The schema as it stands at step 2: fields name the legacy types."

    use Ecto.Schema

    alias Encryptor.Ecto.TestRunbook.Legacy

    @type t :: %__MODULE__{}

    schema "integrations" do
      field(:workspace_id, :string)
      field(:client_secret, Legacy.Binary)
      field(:access_token, Legacy.String)
      field(:refresh_token, Legacy.String)
      field(:access_token_hash, :binary)
    end
  end

  defmodule Integration do
    @moduledoc """
    The schema from step 3 on. Its source is unchanged: the fields name the
    host's type modules, and only those modules changed.
    """

    use Ecto.Schema

    import Encryptor.Ecto.BlindIndex

    alias Encryptor.Ecto.TestRunbook.Encrypted

    @type t :: %__MODULE__{}

    schema "integrations" do
      field(:workspace_id, :string)
      field(:client_secret, Encrypted.Binary)
      field(:access_token, Encrypted.String)
      field(:refresh_token, Encrypted.String)
      field(:access_token_hash, :binary)
      field(:access_token_index, :binary)
      blind_index(:access_token, :access_token_index)
    end

    @doc "Step 7's changeset: the keyed index and, until the drop, the legacy hash."
    @spec changeset(t(), map()) :: Ecto.Changeset.t()
    def changeset(integration, attrs) do
      integration
      |> Ecto.Changeset.cast(attrs, [:workspace_id, :client_secret, :access_token, :refresh_token])
      |> put_index(:access_token, :access_token_index)
      |> put_legacy_hash()
    end

    defp put_legacy_hash(changeset) do
      case Ecto.Changeset.get_change(changeset, :access_token) do
        nil ->
          changeset

        token ->
          Ecto.Changeset.put_change(changeset, :access_token_hash, :crypto.hash(:sha256, token))
      end
    end
  end

  defmodule FinalIntegration do
    @moduledoc "The schema after steps 7 and 8: no legacy hash, no `legacy:`."

    use Ecto.Schema

    import Encryptor.Ecto.BlindIndex

    alias Encryptor.Ecto.TestRunbook.Final

    @type t :: %__MODULE__{}

    schema "integrations" do
      field(:workspace_id, :string)
      field(:client_secret, Final.Binary)
      field(:access_token, Final.String)
      field(:refresh_token, Final.String)
      field(:access_token_index, :binary)
      blind_index(:access_token, :access_token_index)
    end
  end

  defmodule Migration do
    @moduledoc "Step 4's plan: the three columns, each from its legacy type."

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestRunbook.Integration do
      scope_from :workspace_id

      field :client_secret,
        from: Encryptor.Ecto.TestRunbook.Legacy.Binary,
        to: Encryptor.Ecto.TestRunbook.Encrypted.Binary,
        source_authenticated: true

      field :access_token,
        from: Encryptor.Ecto.TestRunbook.Legacy.String,
        to: Encryptor.Ecto.TestRunbook.Encrypted.String,
        source_authenticated: true

      field :refresh_token,
        from: Encryptor.Ecto.TestRunbook.Legacy.String,
        to: Encryptor.Ecto.TestRunbook.Encrypted.String,
        source_authenticated: true
    end
  end

  defmodule Rollback do
    @moduledoc """
    The runbook's reverse plan: the same plan with `from:` and `to:` swapped.

    No `source_authenticated:` anywhere, because every `from:` is one of this
    package's own types.
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestRunbook.Integration do
      scope_from :workspace_id

      field :client_secret,
        from: Encryptor.Ecto.TestRunbook.Encrypted.Binary,
        to: Encryptor.Ecto.TestRunbook.Legacy.Binary

      field :access_token,
        from: Encryptor.Ecto.TestRunbook.Encrypted.String,
        to: Encryptor.Ecto.TestRunbook.Legacy.String

      field :refresh_token,
        from: Encryptor.Ecto.TestRunbook.Encrypted.String,
        to: Encryptor.Ecto.TestRunbook.Legacy.String
    end
  end
end
