defmodule Encryptor.Ecto.GcpKmsLive do
  @moduledoc """
  Runs `Encryptor.Ecto.KeyStore`'s `"gcp_kms_ciphertext"` rows against a live
  Cloud KMS test key, with Postgres.

  `Encryptor.Ecto.GcpKmsLiveTest` is the test; this module reads the key's
  name from the environment, finds the credentials, starts the token server
  and the HTTP pool, and records which Cloud KMS call answered which status.
  CI's `gcp-kms-integration` job authenticates with Workload Identity
  Federation, sets the variables below, and runs
  `mix test --only gcp_kms_integration`. Locally the tag is excluded by
  default; `docs/guides/live-kms-suites.md` says how a maintainer runs it.

    * `GCP_KMS_KEY` - the resource name of a `CryptoKey` the credentials may
      encrypt and decrypt with, in the form
      `projects/*/locations/*/keyRings/*/cryptoKeys/*`.
    * `GOOGLE_APPLICATION_CREDENTIALS` - a credentials file. Unset, the
      gcloud CLI's Application Default Credentials file is read instead.

  With the key name unset or empty the tagged tests are skipped; with
  `ECTO_REQUIRE_GCP_KMS=1` (CI sets it) they fail instead.

  Every row the suite provisions names the test key's own `CryptoKey` id, so
  a provision's `CreateCryptoKey` names a key that already exists and never
  mints a new one: a `CryptoKey` cannot be deleted. The suite destroys no key
  version either; its shred is the row delete, `Encryptor.Ecto.KeyStore.shred/3`.

  The token server and the HTTP pool come from the shape of encryptor's own
  live Cloud KMS suite.

  ## Never in the output

  The key name arrives as a CI secret, and a CI log masks a secret only as a
  whole string. The pieces this module splits out of a name (a project, a
  location, a key ring, a key id) would print in clear, and so would the
  material a key unwraps to. Nothing here renders either: a failure message
  carries a call kind, an HTTP status or a reason tag, never a URL, a name,
  a state, a row or a key.
  """

  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.TestKeyStore
  alias Encryptor.Ecto.TestRepo

  @goth __MODULE__.Goth
  @finch __MODULE__.Finch

  @key_name ~r{\Aprojects/([^/]+)/locations/([^/]+)/keyRings/([^/]+)/cryptoKeys/([^/]+)\z}

  @doc "The token server's name, as the provider's `:goth` option takes it."
  @spec goth() :: atom()
  def goth, do: @goth

  @doc "The HTTP pool's name."
  @spec finch() :: atom()
  def finch, do: @finch

  @doc "Whether the key name is set."
  @spec present?() :: boolean()
  def present?, do: env("GCP_KMS_KEY") != nil

  @doc "Whether an absent key name must fail rather than skip."
  @spec required?() :: boolean()
  def required?, do: System.get_env("ECTO_REQUIRE_GCP_KMS") == "1"

  @doc "The message an absent key name is reported with."
  @spec absent_message() :: String.t()
  def absent_message do
    "GCP_KMS_KEY is unset; the moduledoc of Encryptor.Ecto.GcpKmsLive " <>
      "(test/support/gcp_kms_live.ex) and docs/guides/live-kms-suites.md say how to run the suite"
  end

  @doc """
  The test key, split into the provider's options.

  Answers `{:error, message}` when `GCP_KMS_KEY` is unset or not a
  `CryptoKey` resource name; the message names the variable and never its
  value.
  """
  @spec key() ::
          {:ok,
           %{project: String.t(), location: String.t(), key_ring: String.t(), key_id: String.t()}}
          | {:error, String.t()}
  def key do
    with {:set, value} when value != nil <- {:set, env("GCP_KMS_KEY")},
         [_whole, project, location, key_ring, key_id] <- Regex.run(@key_name, value) do
      {:ok, %{project: project, location: location, key_ring: key_ring, key_id: key_id}}
    else
      {:set, nil} ->
        {:error, "GCP_KMS_KEY is unset"}

      nil ->
        {:error,
         "GCP_KMS_KEY is not a CryptoKey resource name " <>
           "(projects/*/locations/*/keyRings/*/cryptoKeys/*)"}
    end
  end

  @doc """
  The key store's `:gcp_kms` options for the test key: the provider's
  options less the two the key store supplies.
  """
  @spec gcp_kms_opts(map()) :: keyword()
  def gcp_kms_opts(key) do
    [
      project: key.project,
      location: key.location,
      key_ring: key.key_ring,
      http_client: __MODULE__.Http,
      goth: @goth
    ]
  end

  @doc """
  The key store's options for the test key: the GCP branch, the test
  repository, the default table and no root vault, so every row it reads is
  one Cloud KMS unwraps.
  """
  @spec key_store_opts(map()) :: keyword()
  def key_store_opts(key) do
    [
      repo: TestRepo,
      reference_subkey: TestKeyStore.reference_subkey(),
      gcp_kms: gcp_kms_opts(key)
    ]
  end

  @doc "Key store state for the test key, resolved as the vault resolves it."
  @spec key_store_state(map()) :: {:ok, term()} | {:error, term()}
  def key_store_state(key), do: KeyStore.init(key_store_opts(key))

  @doc """
  The token source the credentials file describes, in `Goth`'s terms.

  `GOOGLE_APPLICATION_CREDENTIALS` names the file; unset, the gcloud CLI's
  Application Default Credentials file is read. An `external_account` file
  (what Workload Identity Federation writes) is `Goth`'s
  `:workload_identity` source, an `authorized_user` file its
  `:refresh_token` source, a `service_account` file its `:service_account`
  source. The file's contents are never put in the message.
  """
  @spec token_source() :: {:ok, tuple()} | {:error, String.t()}
  def token_source do
    path =
      env("GOOGLE_APPLICATION_CREDENTIALS") ||
        Path.expand("~/.config/gcloud/application_default_credentials.json")

    with {:ok, contents} <- read(path),
         {:ok, %{} = credentials} <- decode(contents) do
      case credentials["type"] do
        "external_account" -> {:ok, {:workload_identity, credentials}}
        "authorized_user" -> {:ok, {:refresh_token, credentials}}
        "service_account" -> {:ok, {:service_account, credentials}}
        _other -> {:error, "the credentials file is of a type this suite does not read"}
      end
    end
  end

  @doc """
  The children the suite starts: an HTTP pool and a `Goth` server.

  The `Goth` server's retry delay is an hour, so a token it cannot fetch is
  answered as an error to the provider (which reads it as
  `{:token, :unavailable}`) and never retried into the crash `Goth` raises
  after its last retry: that crash's message carries the token endpoint's
  response body.
  """
  @spec children(tuple()) :: [Supervisor.child_spec() | {module(), keyword()}]
  def children(source) do
    [
      {Finch, name: @finch},
      {Goth,
       name: @goth,
       source: source,
       prefetch: :sync,
       max_retries: 1_000,
       retry_delay: fn _attempt -> :timer.hours(1) end}
    ]
  end

  @doc """
  Every call the HTTP client made from the calling process since the last
  read, oldest first, as `{kind, status}`: the kind is `:create`, `:encrypt`
  or `:decrypt`, the status an HTTP status or `:transport` when the request
  did not complete.
  """
  @spec calls() :: [{atom(), non_neg_integer() | :transport}]
  def calls, do: drain([])

  defp drain(acc) do
    receive do
      {__MODULE__, :call, kind, status} -> drain([{kind, status} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc false
  def record(kind, status), do: send(self(), {__MODULE__, :call, kind, status})

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, _reason} ->
        {:error,
         "no credentials: set GOOGLE_APPLICATION_CREDENTIALS, or run " <>
           "`gcloud auth application-default login`"}
    end
  end

  defp decode(contents) do
    case JSON.decode(contents) do
      {:ok, %{} = credentials} -> {:ok, credentials}
      _other -> {:error, "the credentials file is not a JSON object"}
    end
  end
end

defmodule Encryptor.Ecto.GcpKmsLive.Http do
  @moduledoc """
  The provider's HTTP client for the live suite: the thin wrapper over
  `Finch` that `Encryptor.Provider.GcpKms`'s moduledoc asks a host for.

  It reports each call to the calling process as a call kind and a status
  (`Encryptor.Ecto.GcpKmsLive.calls/0`), never the URL, which carries the
  key's resource name. The key store unwraps a row in the process that asked
  for the key, so a vault call or a `Repo` read made by the test is reported
  to the test.
  """

  alias Encryptor.Ecto.GcpKmsLive

  @doc false
  def request(method, url, headers, body, opts) do
    response =
      method
      |> Finch.build(url, headers, body)
      |> Finch.request(GcpKmsLive.finch(), receive_timeout: Keyword.fetch!(opts, :timeout))

    GcpKmsLive.record(kind(url), status(response))

    case response do
      {:ok, %Finch.Response{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, _exception} -> {:error, :request_failed}
    end
  end

  defp kind(url) do
    cond do
      String.ends_with?(url, ":encrypt") -> :encrypt
      String.ends_with?(url, ":decrypt") -> :decrypt
      String.contains?(url, "cryptoKeyId=") -> :create
      true -> :other
    end
  end

  defp status({:ok, %Finch.Response{status: status}}), do: status
  defp status({:error, _exception}), do: :transport
end

defmodule Encryptor.Ecto.GcpKmsLive.Scope do
  @moduledoc """
  The scoped vault the live Cloud KMS suite writes through: its provider is
  `Encryptor.Ecto.KeyStore` on the test repository, configured with `:gcp_kms`
  on the test key and no root vault, so every key it resolves is a
  `"gcp_kms_ciphertext"` row Cloud KMS unwraps.

  `cache: false`, so every operation resolves its key from the table and
  reaches Cloud KMS: a cached key is a call that did not happen, and a shred
  the suite asserts on must be seen on the very next read.
  """

  use Encryptor.Vault,
    otp_app: :encryptor_ecto,
    context_profile: :scoped,
    algorithm_suite_id: 0x0478,
    required_context: ["table", "column"],
    cache: false

  alias Encryptor.Ecto.GcpKmsLive
  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.TestKeyStore

  @doc "Layer 5: the key store on the test key, and the reference subkey."
  def init(config) do
    {:ok, key} = GcpKmsLive.key()

    {:ok,
     Keyword.merge(config,
       provider: {KeyStore, GcpKmsLive.key_store_opts(key)},
       reference_subkey: TestKeyStore.reference_subkey()
     )}
  end
end

defmodule Encryptor.Ecto.GcpKmsLive.Value do
  @moduledoc "An encrypted field on the live Cloud KMS suite's vault, scoped by the process."

  use Encryptor.Ecto.Binary, vault: Encryptor.Ecto.GcpKmsLive.Scope
end

defmodule Encryptor.Ecto.GcpKmsLive.Row do
  @moduledoc "A row of `live_gcp_kms_values`: a scope id and one encrypted value."

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "live_gcp_kms_values" do
    field(:scope_id, :string)
    field(:value, Encryptor.Ecto.GcpKmsLive.Value)
  end
end
