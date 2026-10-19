defmodule Encryptor.Ecto.AwsKmsLiveTest do
  @moduledoc """
  An encrypted Ecto field through Postgres under a scoped vault on
  `Encryptor.Provider.Kms`, against a live AWS KMS test key.

  Tagged `:aws_kms_integration`, which `test/test_helper.exs` excludes by
  default; CI's `aws-kms-integration` job runs it with
  `mix test --only aws_kms_integration`. `Encryptor.Ecto.AwsKmsLive` reads the
  key's ARN and the credentials, and with `ECTO_REQUIRE_AWS_KMS=1` (CI sets
  it) an absent ARN fails this module rather than skipping it.
  `docs/guides/live-kms-suites.md` says how a maintainer runs it.

  The key store has no row shape AWS KMS wraps (`Encryptor.Ecto.AwsKmsLive`,
  "Why the key store is not in this suite"), so this module drives an
  encrypted field on `live_aws_kms_values` whose vault,
  `Encryptor.Ecto.AwsKmsLive.Vault`, names the one test key:

    1. a write calls `GenerateDataKey` on the test key and puts a ciphertext
       in the column;
    2. a read of that row calls `Decrypt` and hands back exactly the value
       written;
    3. the same row read under another scope does not load: the vault
       requires `scope_ref`, and the engine leaves a required pair out of the
       header, so the reader's own `scope_ref` reaches `Decrypt` in the
       encryption context and KMS answers `InvalidCiphertextException` (400).
       The engine then retries once under the header's stored context alone,
       which lacks the writer's `scope_ref`, and KMS refuses that too; the
       field raises `Encryptor.Ecto.DecryptError`.

  The wrong-key case is therefore a wrong binding on the one usable key: the
  read names the right key under a scope the data key was not generated for,
  the cross-scope binding encryptor's own live AWS KMS suite uses. A second
  key, one the credentials hold no grant on, is not part of this suite.

  No assertion here renders a row, an exception, a key ARN or a plaintext:
  each compares inside the test and fails with a call kind, a status or a
  reason tag (`Encryptor.Ecto.AwsKmsLive`, "Never in the output").
  """

  use Encryptor.Ecto.RepoCase, async: false

  alias Ecto.Adapters.SQL
  alias Encryptor.Ecto.AwsKmsLive
  alias Encryptor.Ecto.AwsKmsLive.Row
  alias Encryptor.Ecto.AwsKmsLive.Vault, as: LiveVault
  alias Encryptor.Ecto.DecryptError
  alias Encryptor.Ecto.Scope

  @moduletag :aws_kms_integration

  unless AwsKmsLive.present?() or AwsKmsLive.required?() do
    @moduletag skip: AwsKmsLive.absent_message()
  end

  setup_all do
    # Reached without the ARN only when it is required (CI): fail.
    fetch!(AwsKmsLive.key_arn())
    fetch!(AwsKmsLive.credentials())

    {:ok, _apps} = Application.ensure_all_started(:finch)

    for child <- AwsKmsLive.children(), do: start_supervised!(child)

    case start_supervised(LiveVault) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> flunk("the live vault did not start")
    end

    :ok
  end

  setup do
    # Calls a previous test left unread are not this test's.
    AwsKmsLive.calls()
    :ok
  end

  # sabotage (on a copy whose client answered from an in-memory AES-GCM
  # keyring bound to the encryption context and recorded 200 or 400 per call;
  # the live key was not used): made the client hand back other bytes than
  # the data key Decrypt unwrapped - red, the read raised DecryptError.
  test "writes a field under the test key and reads back exactly the value written" do
    selector = selector()
    plaintext = :crypto.strong_rand_bytes(48)

    row = write!(selector, plaintext)
    assert [{:generate_data_key, 200}] == AwsKmsLive.calls()

    %{rows: [[stored]]} =
      SQL.query!(TestRepo, "SELECT value FROM live_aws_kms_values WHERE id = $1", [row.id])

    sealed =
      is_binary(stored) and stored != plaintext and byte_size(stored) > byte_size(plaintext)

    assert sealed, "the column does not hold a ciphertext"

    assert {:read, true} == read(selector, row.id, plaintext)
    assert [{:decrypt, 200}] == AwsKmsLive.calls()
  end

  # sabotage (the same copy): made the in-memory keyring bind no encryption
  # context - red, Decrypt answered 200 under the other scope's binding and
  # the row loaded.
  test "refuses to load a field under another scope's binding" do
    owner = selector()
    other = selector()

    row = write!(owner, :crypto.strong_rand_bytes(48))
    AwsKmsLive.calls()

    assert {:refused, :decrypt_failed} == read(other, row.id, nil)
    assert [{:decrypt, 400}, {:decrypt, 400}] == AwsKmsLive.calls()
  end

  defp fetch!(:ok), do: :ok
  defp fetch!({:ok, value}), do: value
  defp fetch!({:error, message}), do: flunk(message)

  defp selector, do: "live-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp write!(selector, plaintext) do
    Scope.wrap(selector, fn ->
      TestRepo.insert!(%Row{scope_id: selector, value: plaintext})
    end)
  end

  # `{:read, same?}` when the row loads, `{:refused, tag}` when its field does
  # not decrypt, the tag being the vault reason's leading atom. The exception
  # is never rendered: its reason and its engine detail can carry the
  # selector and KMS's error.
  defp read(selector, id, plaintext) do
    Scope.wrap(selector, fn ->
      try do
        {:read, TestRepo.get!(Row, id).value == plaintext}
      rescue
        error in DecryptError -> {:refused, tag(error.reason)}
      end
    end)
  end

  # A reason's leading tag, never its whole term.
  defp tag(%{reason: reason}), do: tag(reason)
  defp tag(reason) when is_tuple(reason), do: elem(reason, 0)
  defp tag(reason) when is_atom(reason), do: reason
  defp tag(_reason), do: :unnameable
end
