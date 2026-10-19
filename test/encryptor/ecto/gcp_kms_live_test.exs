defmodule Encryptor.Ecto.GcpKmsLiveTest do
  @moduledoc """
  `Encryptor.Ecto.KeyStore`'s `"gcp_kms_ciphertext"` rows against a live
  Cloud KMS test key, with Postgres.

  Tagged `:gcp_kms_integration`, which `test/test_helper.exs` excludes by
  default; CI's `gcp-kms-integration` job runs it with
  `mix test --only gcp_kms_integration`. `Encryptor.Ecto.GcpKmsLive` reads the
  key name and the credentials, and with `ECTO_REQUIRE_GCP_KMS=1` (CI sets
  it) an absent key name fails this module rather than skipping it.
  `docs/guides/live-kms-suites.md` says how a maintainer runs it.

  Everything else in the key store's tests runs against
  `Encryptor.Ecto.TestGcpKms`'s fake of the provider's HTTP seam; this module
  is the one place a GCP row meets the service. It drives
  `Encryptor.Ecto.GcpKmsLive.Scope`, a scoped vault whose key store holds only
  GCP rows, through an encrypted field on `live_gcp_kms_values`:

    1. a row written: `Encryptor.Provider.GcpKms.provision/2` against the test
       key (`CreateCryptoKey` finds the key already there, `Encrypt` wraps
       fresh material) and the row inserted as the key store's table holds
       it;
    2. read back: a field written and read through the key store, each
       resolution one `Decrypt` of the row;
    3. rotated: a version-2 row wrapped under the same key and bound to its
       own version, which takes the writes while version 1 still reads;
    4. shredded: `Encryptor.Ecto.KeyStore.shred/3` deleting version 1, then
       the scope, with no Cloud KMS call, after which the values written
       under each deleted version no longer read.

  Every row names the test key's own `CryptoKey` id, so no execution mints a
  `CryptoKey`, and no key version is destroyed: the shred here is the row
  delete. The selector is fresh per test, so the scope's rows are its own.

  No assertion here renders a row, a state, a key name, key material or an
  error term: each compares inside the test and fails with a call kind, a
  status or a reason tag (`Encryptor.Ecto.GcpKmsLive`, "Never in the
  output").
  """

  use Encryptor.Ecto.RepoCase, async: false

  alias Ecto.Adapters.SQL
  alias Encryptor.Ecto.DecryptError
  alias Encryptor.Ecto.GcpKmsLive
  alias Encryptor.Ecto.GcpKmsLive.Row
  alias Encryptor.Ecto.GcpKmsLive.Scope, as: LiveScope
  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.KeyStore.Shred
  alias Encryptor.Ecto.Scope
  alias Encryptor.Ecto.TestKeyStore
  alias Encryptor.Envelope
  alias Encryptor.Envelope.WrappedKey
  alias Encryptor.Key.Aes
  alias Encryptor.Provider.GcpKms
  alias Encryptor.Provider.GcpKms.Aad
  alias Encryptor.Provider.GcpKms.Api

  @moduletag :gcp_kms_integration

  unless GcpKmsLive.present?() or GcpKmsLive.required?() do
    @moduletag skip: GcpKmsLive.absent_message()
  end

  setup_all do
    # Reached without the key name only when it is required (CI): fail.
    key = fetch!(GcpKmsLive.key())
    source = fetch!(GcpKmsLive.token_source())

    {:ok, _apps} = Application.ensure_all_started(:goth)

    for child <- GcpKmsLive.children(source), do: start_supervised!(child)

    case start_supervised(LiveScope) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> flunk("the live vault did not start")
    end

    state =
      case GcpKmsLive.key_store_state(key) do
        {:ok, state} -> state
        {:error, reason} -> flunk("the key store answered #{inspect(tag(reason))} at init")
      end

    %{key: key, state: state}
  end

  setup do
    # Calls a previous test left unread are not this test's.
    GcpKmsLive.calls()
    :ok
  end

  # sabotage: Encryptor.Ecto.Binary.load_arm/2 handing back the stored bytes
  # undecrypted, red - the read-back compared unequal (on a copy whose HTTP
  # client answered from Encryptor.Ecto.TestGcpKms.Http and recorded each
  # status; the live key was not used).
  test "writes a row on the test key, and a field written through it reads back", ctx do
    selector = selector()

    provision!(ctx, selector)
    assert [{:create, 409}, {:encrypt, 200}] == GcpKmsLive.calls()

    plaintext = :crypto.strong_rand_bytes(48)
    row = write!(selector, plaintext)
    assert [{:decrypt, 200}] == GcpKmsLive.calls()

    %{rows: [[stored]]} =
      SQL.query!(TestRepo, "SELECT value FROM live_gcp_kms_values WHERE id = $1", [row.id])

    sealed =
      is_binary(stored) and stored != plaintext and byte_size(stored) > byte_size(plaintext)

    assert sealed, "the column does not hold a ciphertext"

    assert {:read, true} == read(selector, row.id, plaintext)
    assert [{:decrypt, 200}] == GcpKmsLive.calls()
  end

  # sabotage: KeyStore.encryption_key/2 unwrapping the oldest row instead of
  # the newest, red - the rotation's row was not the one served. Separately,
  # a one-version shred deleting the newest version instead of the named
  # one, red - the shred record named version 2 (on the same copy).
  test "rotates to a second row, then shreds one version and the scope", ctx do
    selector = selector()

    provisioned = provision!(ctx, selector)
    first = :crypto.strong_rand_bytes(48)
    first_row = write!(selector, first)

    # The rotation: version 2, wrapped under the same CryptoKey and bound to
    # its own version, as `provision/2` binds version 1.
    material = :crypto.strong_rand_bytes(32)
    rotate!(ctx, provisioned, material)
    GcpKmsLive.calls()

    newest =
      case KeyStore.encryption_key(ctx.state, selector) do
        {:ok, %Aes{material: current}} -> current == material
        {:error, reason} -> flunk("encryption_key answered #{inspect(tag(reason))}; #{calls()}")
      end

    assert newest, "the newest row is not the one the rotation wrote"
    assert [{:decrypt, 200}] == GcpKmsLive.calls()

    assert {:keys, 2} == keys(ctx.state, selector)
    assert [{:decrypt, 200}, {:decrypt, 200}] == GcpKmsLive.calls()

    second = :crypto.strong_rand_bytes(48)
    second_row = write!(selector, second)

    assert {:read, true} == read(selector, first_row.id, first)
    assert {:read, true} == read(selector, second_row.id, second)
    GcpKmsLive.calls()

    assert {:shred, :version, [1], [2]} == shred(selector, version: 1)
    assert [] == GcpKmsLive.calls()

    # Each read unwraps the one row left, version 2; the value written under
    # version 1 then finds no key for its header.
    assert :refused == read(selector, first_row.id, first)
    assert {:read, true} == read(selector, second_row.id, second)
    assert [{:decrypt, 200}, {:decrypt, 200}] == GcpKmsLive.calls()

    assert {:shred, :scope, [2], []} == shred(selector, version: :all)
    assert [] == GcpKmsLive.calls()

    assert {:error, :unknown_key} == keys(ctx.state, selector)
    assert :refused == read(selector, second_row.id, second)
  end

  defp fetch!({:ok, value}), do: value
  defp fetch!({:error, message}), do: flunk(message)

  defp selector, do: "live-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  # The provider's state for the test key, its `CryptoKey` id pinned to that
  # key so a provision never mints one.
  defp gcp_state(ctx) do
    opts =
      GcpKmsLive.gcp_kms_opts(ctx.key) ++
        [
          reference_subkey: TestKeyStore.reference_subkey(),
          store: fn _scope_ref -> {:ok, []} end,
          key_id_fun: fn _selector -> ctx.key.key_id end
        ]

    case GcpKms.init(opts) do
      {:ok, state} -> state
      {:error, reason} -> flunk("init answered #{inspect(tag(reason))}")
    end
  end

  # A host's provisioning, as `docs/guides/gcp-kms-key-store.md` Step 4 writes
  # it: the provider mints version 1 and the row goes into the table with
  # `wrapping_shape` set.
  defp provision!(ctx, selector) do
    case GcpKms.provision(gcp_state(ctx), selector) do
      {:ok, provisioned} ->
        insert!(provisioned)
        provisioned

      {:error, reason} ->
        flunk("provision answered #{inspect(tag(reason))}; #{calls()}")
    end
  end

  defp rotate!(ctx, provisioned, material) do
    aad = provisioned.scope_ref |> Envelope.binding(2, provisioned.namespace) |> Aad.encode()

    case Api.encrypt(gcp_state(ctx), provisioned.key_id, material, aad) do
      {:ok, wrapped} ->
        insert!(%{
          provisioned
          | version: 2,
            name: Envelope.key_name(provisioned.scope_ref, 2),
            wrapped: wrapped
        })

      {:error, failure} ->
        flunk("Encrypt answered #{inspect(tag(failure))}; #{calls()}")
    end
  end

  defp insert!(provisioned) do
    WrappedKey
    |> struct(Map.delete(provisioned, :key_id))
    |> TestKeyStore.insert!(wrapping_shape: "gcp_kms_ciphertext", key_id: provisioned.key_id)
  end

  defp write!(selector, plaintext) do
    Scope.wrap(selector, fn ->
      TestRepo.insert!(%Row{scope_id: selector, value: plaintext})
    end)
  end

  # `{:read, same?}` when the row loads, `:refused` when its field does not
  # decrypt. The exception is never rendered: its reason can carry the
  # selector and an engine detail.
  defp read(selector, id, plaintext) do
    Scope.wrap(selector, fn ->
      try do
        {:read, TestRepo.get!(Row, id).value == plaintext}
      rescue
        DecryptError -> :refused
      end
    end)
  end

  defp keys(state, selector) do
    case KeyStore.decryption_keys(state, selector) do
      {:ok, keys} -> {:keys, length(keys)}
      {:error, reason} -> {:error, tag(reason)}
    end
  end

  defp shred(selector, opts) do
    case KeyStore.shred(LiveScope, selector, opts) do
      {:ok, %Shred{procedure: procedure, versions: versions, remaining: remaining}} ->
        {:shred, procedure, versions, remaining}

      {:error, reason} ->
        {:error, tag(reason)}
    end
  end

  # A reason's leading tag, never its whole term: a reason can carry a
  # selector or a detail that names the key.
  defp tag(reason) when is_tuple(reason), do: elem(reason, 0)
  defp tag(reason) when is_atom(reason), do: reason
  defp tag(_reason), do: :unnameable

  defp calls do
    rendered =
      Enum.map_join(GcpKmsLive.calls(), ", ", fn {kind, status} -> "#{kind} #{status}" end)

    "Cloud KMS calls: [" <> rendered <> "]"
  end
end
