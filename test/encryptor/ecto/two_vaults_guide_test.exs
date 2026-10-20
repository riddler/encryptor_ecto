defmodule Encryptor.Ecto.TwoVaultsGuideTest do
  @moduledoc """
  The two-vaults guide's host, run against real vaults, a real key store and
  real tables.

  `docs/guides/two-vaults-long-and-short-lived-scopes.md` shows a host with an
  owner vault and a grant vault, a schema for each, the built-in
  process resolver on one and a host resolver on the other, and a shred per
  grant. `Encryptor.Ecto.TestTwoVaults` is that code; the first test
  below holds it to the guide's text, and the rest assert what the guide says
  the host sees.

  `async: false` because the three vaults are named processes this module
  starts, and the shred test restarts one of them.
  """

  use Encryptor.Ecto.RepoCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Encryptor.Ecto.DecryptError
  alias Encryptor.Ecto.EncryptError
  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.KeyStore.Shred
  alias Encryptor.Ecto.MissingScopeError
  alias Encryptor.Ecto.Scope
  alias Encryptor.Ecto.TestTwoVaults.GrantRecord
  alias Encryptor.Ecto.TestTwoVaults.GrantRecords
  alias Encryptor.Ecto.TestTwoVaults.GrantScope
  alias Encryptor.Ecto.TestTwoVaults.GrantVault
  alias Encryptor.Ecto.TestTwoVaults.Keys
  alias Encryptor.Ecto.TestTwoVaults.OwnerRecord
  alias Encryptor.Ecto.TestTwoVaults.OwnerVault
  alias Encryptor.Ecto.TestTwoVaults.RootVault

  @guide Path.expand("../../../docs/guides/two-vaults-long-and-short-lived-scopes.md", __DIR__)
  @support Path.expand("../../support/test_two_vaults.ex", __DIR__)

  # The substitutions `Encryptor.Ecto.TestTwoVaults`'s moduledoc names, in
  # the order they apply: the repo alias, then the repo, then the general
  # prefix.
  @substitutions [
    {"alias MyApp.Repo", "alias Encryptor.Ecto.TestRepo, as: Repo"},
    {"MyApp.Repo", "Encryptor.Ecto.TestRepo"},
    {"MyApp.", "Encryptor.Ecto.TestTwoVaults."},
    {":my_app", ":encryptor_ecto"}
  ]

  @owner "owner-1"
  @other_owner "owner-2"
  @grant "grant-1"
  @other_grant "grant-2"

  setup do
    # Stands in for the host's runtime configuration. A fixture root is still
    # key-shaped, so no assertion renders it.
    Application.put_env(
      :encryptor_ecto,
      :root_key_base64,
      Base.encode64(:binary.copy(<<0x4C>>, 32))
    )

    on_exit(fn -> Application.delete_env(:encryptor_ecto, :root_key_base64) end)

    Scope.clear()

    start_supervised!(RootVault)
    start_supervised!(OwnerVault)
    start_supervised!(GrantVault)

    :ok = Keys.provision(:owner, @owner)
    :ok = Keys.provision(:owner, @other_owner)
    :ok = Keys.provision(:grant, @grant)
    :ok = Keys.provision(:grant, @other_grant)

    :ok
  end

  describe "the guide's code" do
    # Sabotage: changed the guide's resolver error atom to
    # `:no_grant_in_request`; this test went red on that block. Every
    # support-file sabotage below also turned this test red.
    test "every defmodule block in the guide is the support file's code" do
      source = File.read!(@support)
      support = source |> strip_moduledocs() |> without_aliases() |> normalize()
      blocks = guide_modules()

      assert length(blocks) >= 9

      for block <- Enum.map(blocks, &substitute/1) do
        assert String.contains?(support, block |> without_aliases() |> normalize()),
               "guide block not found in the support file:\n\n" <> block

        for alias_line <- aliases(block) do
          assert String.contains?(source, alias_line),
                 "guide alias not found in the support file: " <> alias_line
        end
      end
    end
  end

  describe "step 3: each vault reads its own key table" do
    # Sabotage: made `Keys.provision/2` write grant keys into the default
    # table; this test went red, and so did every grant read and write.
    test "the owner's rows are in the default table, the grant's in their own" do
      assert owner_ref = ref(@owner)
      assert grant_ref = ref(@grant)

      assert [1] = key_versions(KeyStore.default_table(), owner_ref)
      assert [] = key_versions(KeyStore.default_table(), grant_ref)
      assert [1] = key_versions(Keys.grant_table(), grant_ref)
      assert [] = key_versions(Keys.grant_table(), owner_ref)
    end
  end

  describe "step 4: the owner vault resolves from the process" do
    # Sabotage: made the owner type module name `GrantVault`; the
    # round trip raised.
    test "an owner's token round-trips under its own scope and fails under another" do
      %OwnerRecord{id: id} =
        Scope.wrap(@owner, fn ->
          TestRepo.insert!(%OwnerRecord{owner_id: @owner, secret_token: "token-1"})
        end)

      assert %OwnerRecord{secret_token: "token-1"} =
               Scope.wrap(@owner, fn -> TestRepo.get!(OwnerRecord, id) end)

      assert_raise DecryptError, fn ->
        Scope.wrap(@other_owner, fn -> TestRepo.get!(OwnerRecord, id) end)
      end
    end

    # Sabotage: made `Encryptor.Ecto.ScopeContext.Process.resolve/2` answer
    # a fixed owner when no scope was set; nothing raised.
    test "with no owner in scope a write raises rather than guessing" do
      assert_raise MissingScopeError, fn ->
        TestRepo.insert!(%OwnerRecord{owner_id: @owner, secret_token: "token-1"})
      end
    end
  end

  describe "step 5: the grant vault resolves from the row" do
    # Sabotage: made `GrantRecords.record/1` swap the two grants; `list/1`
    # raised `DecryptError`. Separately, dropped the `where:` from
    # `GrantRecords.list/1`; the same `list/1` raised on the other grant's row.
    test "a record is written under the grant on its row and read back by grant" do
      assert {:ok, _record} = record(@grant, "note-1")
      assert {:ok, _record} = record(@other_grant, "note-2")

      assert [%GrantRecord{note: "note-1"}] = GrantRecords.list(@grant)
      assert [%GrantRecord{note: "note-2"}] = GrantRecords.list(@other_grant)
    end

    # Sabotage: dropped `validate_required/2` from `GrantRecords.record/1`; the
    # insert crashed instead of returning the invalid changeset.
    test "a changeset with no grant id is refused before anything is encrypted" do
      assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
               GrantRecords.record(%{owner_id: @owner, note: "note-1"})

      assert {"can't be blank", _meta} = changeset.errors[:grant_id]
    end

    # Sabotage: made `GrantScope.resolve/2` answer the first grant
    # whatever was set, so both rows were written under one key; the load
    # read both and nothing raised.
    test "a read whose rows span grants raises instead of answering" do
      {:ok, _record} = record(@grant, "note-1")
      {:ok, _record} = record(@other_grant, "note-2")

      assert_raise DecryptError, fn ->
        GrantScope.with_grant(@grant, fn -> TestRepo.all(GrantRecord) end)
      end
    end

    # Sabotage: made `GrantScope.resolve/2` answer `{:ok, "grant-default"}`
    # when nothing was set; the raise became an `unknown_key` EncryptError.
    test "outside with_grant/2 the resolver refuses, and the type raises" do
      assert_raise MissingScopeError, fn ->
        TestRepo.insert!(%GrantRecord{
          owner_id: @owner,
          grant_id: @grant,
          note: "note-1"
        })
      end
    end

    test "with_grant/2 restores the scope it found, nested or not" do
      GrantScope.with_grant(@grant, fn ->
        GrantScope.with_grant(@other_grant, fn ->
          assert {:ok, @other_grant} = GrantScope.resolve(:dump, %{})
        end)

        assert {:ok, @grant} = GrantScope.resolve(:dump, %{})
      end)

      assert {:error, :no_grant_in_scope} = GrantScope.resolve(:load, %{})
    end
  end

  describe "step 6: shred one grant" do
    # Sabotage: made `Keys.shred_grant/2` shred through the owner
    # vault; the record assertion went red on `{:error, {:unknown_key, _}}`.
    # Removing the vault restart below left this test green: after a
    # whole-scope shred the answers do not depend on the drain, so this test
    # does not pin the cache's behaviour.
    test "deleting the grant's key rows ends that grant and nothing else" do
      {:ok, _record} = record(@grant, "note-1")
      {:ok, _record} = record(@other_grant, "note-2")

      %OwnerRecord{id: record_id} =
        Scope.wrap(@owner, fn ->
          TestRepo.insert!(%OwnerRecord{owner_id: @owner, secret_token: "token-1"})
        end)

      assert [_record] = GrantRecords.list(@grant)

      assert {:ok, %Shred{procedure: :scope, versions: [1]}} =
               Keys.shred_grant(@grant, drain: :skip)

      assert [] = key_versions(Keys.grant_table(), ref(@grant))

      # The runbook's cache drain (encryptor ADR-0005, P3 step 3), done the
      # way the guide offers beside the default wait: restart the vault.
      :ok = stop_supervised(GrantVault)
      start_supervised!(GrantVault)

      assert %DecryptError{reason: {:unknown_key, @grant}} =
               assert_raise(DecryptError, fn -> GrantRecords.list(@grant) end)

      assert %EncryptError{reason: {:unknown_key, @grant}} =
               assert_raise(EncryptError, fn -> record(@grant, "note-3") end)

      assert [%GrantRecord{note: "note-2"}] = GrantRecords.list(@other_grant)

      assert %OwnerRecord{secret_token: "token-1"} =
               Scope.wrap(@owner, fn -> TestRepo.get!(OwnerRecord, record_id) end)

      # Step 4 of the runbook: the ciphertext rows still carry the grant's
      # pseudonym in every header, so they go too.
      assert {:ok, 1} = GrantRecords.forget(@grant)

      assert [] =
               TestRepo.all(from(l in GrantRecord, where: l.grant_id == ^@grant))
    end
  end

  defp record(grant_id, note) do
    GrantRecords.record(%{owner_id: @owner, grant_id: grant_id, note: note})
  end

  defp ref(selector) do
    {:ok, ref} = Encryptor.Envelope.scope_ref(Keys.reference_subkey(), selector)
    ref
  end

  defp key_versions(table, ref) do
    TestRepo.all(from(k in table, where: k.scope_ref == ^ref, select: k.version))
  end

  defp guide_modules do
    ~r/```elixir\n(.*?)```/s
    |> Regex.scan(File.read!(@guide), capture: :all_but_first)
    |> Enum.map(fn [block] -> block end)
    |> Enum.filter(&String.starts_with?(&1, "defmodule "))
  end

  defp substitute(block) do
    Enum.reduce(@substitutions, block, fn {from, to}, acc -> String.replace(acc, from, to) end)
  end

  defp strip_moduledocs(source) do
    source
    |> String.replace(~r/\n  @moduledoc """\n.*?\n  """\n/s, "\n")
    |> String.replace(~r/\n  @moduledoc "[^"\n]*"\n/, "\n")
  end

  # Alias lines are compared one by one rather than in place: credo orders a
  # module's aliases alphabetically, and the substituted repo alias sorts to a
  # different line in each file.
  defp aliases(block) do
    ~r/^\s*(alias .+)$/m
    |> Regex.scan(block, capture: :all_but_first)
    |> Enum.map(fn [line] -> line end)
  end

  defp without_aliases(source), do: String.replace(source, ~r/^\s*alias .+\n/m, "")

  # Line breaks are the formatter's, and a longer module name moves them, so
  # the comparison is over tokens rather than layout.
  defp normalize(source) do
    source
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/([(\[{]) /, "\\1")
    |> String.replace(~r/ ([)\]}])/, "\\1")
    |> String.trim()
  end
end
