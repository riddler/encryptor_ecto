defmodule Encryptor.Ecto.TestGcpKms do
  @moduledoc """
  The furniture a `"gcp_kms_ciphertext"` row resolves through, with no network.

  `Encryptor.Provider.GcpKms` takes its transport from the host - an HTTP
  client module exporting `request/5` and a token server exporting `fetch/1` -
  and that boundary is the seam its own suite fakes. This is the same seam:
  `Http` below answers the three Cloud KMS calls the provider makes, keeping
  one AES-256-GCM key per `CryptoKey` id and binding every ciphertext to the
  additional authenticated data the provider sends. So a row's wrapping here
  is produced by the provider's real `provision/2`, and unwrapping it runs the
  provider's real binding check: a row whose `tenant_ref`, `version` or
  `namespace` was edited fails to decrypt exactly as it would against the
  service.

  `outage/1` makes the fake answer a transport failure for the calling
  process, which is the arm a real network partition would take.
  `destroyed/2` makes it refuse `Encrypt` and `Decrypt` under one `CryptoKey`
  for the calling process, which is what the service answers once that key's
  only version has been through `DestroyCryptoKeyVersion`; setting it back to
  `false` is the restore.
  """

  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.TestKeyStore
  alias Encryptor.Envelope.WrappedKey
  alias Encryptor.Provider.GcpKms

  @doc "The `:gcp_kms` options a host would write for this fake service."
  @spec opts() :: keyword()
  def opts do
    [
      project: "test-project",
      location: "us-east1",
      key_ring: "test-ring",
      http_client: __MODULE__.Http,
      goth: {__MODULE__.Token, :test}
    ]
  end

  @doc "Key store state configured with the GCP branch's client."
  @spec state(keyword()) :: term()
  def state(overrides \\ []), do: TestKeyStore.state(Keyword.put(overrides, :gcp_kms, opts()))

  @doc """
  Mints a selector's master key through the provider and stores the row.

  `Encryptor.Provider.GcpKms.provision/2` mints version 1 and nothing else;
  its return carries `key_id`, which goes to the column of the same name.
  """
  @spec provision!(String.t(), keyword()) :: map()
  def provision!(selector, overrides \\ []) do
    {:ok, gcp} =
      GcpKms.init(
        Keyword.merge(opts(),
          reference_subkey: TestKeyStore.reference_subkey(),
          store: fn _scope_ref -> {:ok, []} end
        )
      )

    {:ok, provisioned} = GcpKms.provision(gcp, selector)

    WrappedKey
    |> struct(Map.delete(provisioned, :key_id))
    |> TestKeyStore.insert!(
      Keyword.merge(
        [wrapping_shape: "gcp_kms_ciphertext", key_id: provisioned.key_id],
        overrides
      )
    )

    provisioned
  end

  @doc "Makes the fake service unreachable from the calling process."
  @spec outage(boolean()) :: :ok
  def outage(down?) do
    Process.put({__MODULE__, :outage}, down?)
    :ok
  end

  @doc """
  Marks a `CryptoKey`'s version destroyed, or restored, for the calling process.

  `Encryptor.Provider.GcpKms.provision/2` creates each `CryptoKey` with one
  version and never rotates it, so destroying that version is destroying
  every version the key has. The fake answers a destroyed key the way the
  service answers a version that is not enabled: a `400` naming
  `FAILED_PRECONDITION`.
  """
  @spec destroyed(String.t(), boolean()) :: :ok
  def destroyed(key_id, destroyed?) do
    Process.put({__MODULE__, :destroyed, key_id}, destroyed?)
    :ok
  end

  @doc "The default table name, for a test that edits a row in place."
  @spec table() :: String.t()
  def table, do: KeyStore.default_table()

  defmodule Token do
    @moduledoc "A token server with Goth's return shape and nothing behind it."

    @doc "Always a token: the fake service does not check it."
    @spec fetch(term()) :: {:ok, %{token: String.t()}}
    def fetch(_name), do: {:ok, %{token: "test-token"}}
  end

  defmodule Http do
    @moduledoc """
    Cloud KMS `CreateCryptoKey`, `Encrypt` and `Decrypt`, in memory.

    Each `CryptoKey` id gets its own AES-256-GCM key, derived from the id, so
    the service needs no state between calls. A ciphertext is
    `iv <> tag <> bytes`; `Decrypt` under different additional authenticated
    data fails authentication and answers `400`, as the service does.
    """

    @iv_bytes 12
    @tag_bytes 16

    @doc "The `request/5` contract `Encryptor.Provider.GcpKms` documents."
    @spec request(atom(), String.t(), list(), binary(), keyword()) ::
            {:ok, %{status: non_neg_integer(), body: binary()}} | {:error, term()}
    def request(:post, url, _headers, body, _opts) do
      if Process.get({Encryptor.Ecto.TestGcpKms, :outage}, false),
        do: {:error, :econnrefused},
        else: route(url, JSON.decode!(body))
    end

    defp route(url, body) do
      cond do
        String.contains?(url, "/cryptoKeys?cryptoKeyId=") -> ok(%{})
        String.ends_with?(url, ":encrypt") -> use_key(key_id(url, ":encrypt"), &encrypt/2, body)
        String.ends_with?(url, ":decrypt") -> use_key(key_id(url, ":decrypt"), &decrypt/2, body)
      end
    end

    defp use_key(key_id, call, body) do
      if Process.get({Encryptor.Ecto.TestGcpKms, :destroyed, key_id}, false),
        do: {:ok, %{status: 400, body: ~s({"error":{"status":"FAILED_PRECONDITION"}})}},
        else: call.(key_id, body)
    end

    defp encrypt(key_id, %{"plaintext" => plaintext, "additionalAuthenticatedData" => aad}) do
      iv = :crypto.strong_rand_bytes(@iv_bytes)

      {bytes, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key(key_id),
          iv,
          Base.decode64!(plaintext),
          Base.decode64!(aad),
          true
        )

      ok(%{"ciphertext" => Base.encode64(iv <> tag <> bytes)})
    end

    defp decrypt(key_id, %{"ciphertext" => ciphertext, "additionalAuthenticatedData" => aad}) do
      <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), bytes::binary>> =
        Base.decode64!(ciphertext)

      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key(key_id),
             iv,
             bytes,
             Base.decode64!(aad),
             tag,
             false
           ) do
        plaintext when is_binary(plaintext) -> ok(%{"plaintext" => Base.encode64(plaintext)})
        :error -> {:ok, %{status: 400, body: ~s({"error":{"status":"INVALID_ARGUMENT"}})}}
      end
    end

    defp key_id(url, verb) do
      url
      |> String.trim_trailing(verb)
      |> String.split("/cryptoKeys/")
      |> List.last()
    end

    defp key(key_id), do: :crypto.hash(:sha256, ["test-kms/", key_id])

    defp ok(map), do: {:ok, %{status: 200, body: JSON.encode!(map)}}
  end

  defmodule Scope do
    @moduledoc """
    A scoped vault over the key store with the GCP branch configured.

    The same shape as `Encryptor.Ecto.TestKeyStore.Scope`, plus `:gcp_kms`,
    so a value can be written and read back under a key whose only stored
    copy is a GCP KMS ciphertext.
    """

    use Encryptor.Vault,
      otp_app: :encryptor_ecto,
      context_profile: :scoped,
      algorithm_suite_id: 0x0478,
      required_context: ["table", "column"],
      cache: false

    alias Encryptor.Ecto.KeyStore
    alias Encryptor.Ecto.TestGcpKms
    alias Encryptor.Ecto.TestKeyStore

    @doc "Layer 5: the provider and the reference subkey, both key material."
    def init(config) do
      {:ok,
       Keyword.merge(config,
         provider: {KeyStore, TestKeyStore.provider_opts(gcp_kms: TestGcpKms.opts())},
         reference_subkey: TestKeyStore.reference_subkey()
       )}
    end
  end
end
