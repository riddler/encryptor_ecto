defmodule Encryptor.Ecto.TwoVaultsGuideTest do
  @moduledoc """
  The two-vaults guide's host, run against real vaults, a real key store and
  real tables.

  `docs/guides/two-vaults-customer-and-agreement.md` shows a host with a
  customer vault and an agreement vault, a schema for each, the built-in
  process resolver on one and a host resolver on the other, and a shred per
  agreement. `Encryptor.Ecto.TestTwoVaults` is that code; the first test
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
  alias Encryptor.Ecto.TestTwoVaults.Account
  alias Encryptor.Ecto.TestTwoVaults.AgreementScope
  alias Encryptor.Ecto.TestTwoVaults.AgreementVault
  alias Encryptor.Ecto.TestTwoVaults.CustomerVault
  alias Encryptor.Ecto.TestTwoVaults.Keys
  alias Encryptor.Ecto.TestTwoVaults.Loans
  alias Encryptor.Ecto.TestTwoVaults.RootVault
  alias Encryptor.Ecto.TestTwoVaults.SharedLoan

  @guide Path.expand("../../../docs/guides/two-vaults-customer-and-agreement.md", __DIR__)
  @support Path.expand("../../support/test_two_vaults.ex", __DIR__)

  # The substitutions `Encryptor.Ecto.TestTwoVaults`'s moduledoc names, in
  # the order they apply: the repo alias, then the repo, then the general
  # prefix.
  @substitutions [
    {"alias Library.Repo", "alias Encryptor.Ecto.TestRepo, as: Repo"},
    {"Library.Repo", "Encryptor.Ecto.TestRepo"},
    {"Library.", "Encryptor.Ecto.TestTwoVaults."},
    {":library", ":encryptor_ecto"}
  ]

  @customer "lib_branch_north"
  @other_customer "lib_branch_south"
  @agreement "agr_2026_reading_study"
  @other_agreement "agr_2026_holds_pilot"

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
    start_supervised!(CustomerVault)
    start_supervised!(AgreementVault)

    :ok = Keys.provision(:customer, @customer)
    :ok = Keys.provision(:customer, @other_customer)
    :ok = Keys.provision(:agreement, @agreement)
    :ok = Keys.provision(:agreement, @other_agreement)

    :ok
  end

  describe "the guide's code" do
    # Sabotage: changed the guide's resolver error atom to
    # `:no_agreement_in_request`; this test went red on that block. Every
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
    # Sabotage: made `Keys.provision/2` write agreement keys into the default
    # table; this test went red, and so did every agreement read and write.
    test "the customer's rows are in the default table, the agreement's in their own" do
      assert customer_ref = ref(@customer)
      assert agreement_ref = ref(@agreement)

      assert [1] = key_versions(KeyStore.default_table(), customer_ref)
      assert [] = key_versions(KeyStore.default_table(), agreement_ref)
      assert [1] = key_versions(Keys.agreement_table(), agreement_ref)
      assert [] = key_versions(Keys.agreement_table(), customer_ref)
    end
  end

  describe "step 4: the customer vault resolves from the process" do
    # Sabotage: made the customer type module name `AgreementVault`; the
    # round trip raised.
    test "a customer's token round-trips under its own scope and fails under another" do
      %Account{id: id} =
        Scope.wrap(@customer, fn ->
          TestRepo.insert!(%Account{customer_id: @customer, catalog_api_token: "tok-north"})
        end)

      assert %Account{catalog_api_token: "tok-north"} =
               Scope.wrap(@customer, fn -> TestRepo.get!(Account, id) end)

      assert_raise DecryptError, fn ->
        Scope.wrap(@other_customer, fn -> TestRepo.get!(Account, id) end)
      end
    end

    # Sabotage: made `Encryptor.Ecto.ScopeContext.Process.resolve/2` answer
    # a fixed customer when no scope was set; nothing raised.
    test "with no customer in scope a write raises rather than guessing" do
      assert_raise MissingScopeError, fn ->
        TestRepo.insert!(%Account{customer_id: @customer, catalog_api_token: "tok-north"})
      end
    end
  end

  describe "step 5: the agreement vault resolves from the row" do
    # Sabotage: made `Loans.record/1` swap the two agreements; `list/1`
    # raised `DecryptError`. Separately, dropped the `where:` from
    # `Loans.list/1`; the same `list/1` raised on the other agreement's row.
    test "a loan is written under the agreement on its row and read back by agreement" do
      assert {:ok, _loan} = record(@agreement, "reader@example.com")
      assert {:ok, _loan} = record(@other_agreement, "other@example.com")

      assert [%SharedLoan{patron_email: "reader@example.com"}] = Loans.list(@agreement)
      assert [%SharedLoan{patron_email: "other@example.com"}] = Loans.list(@other_agreement)
    end

    # Sabotage: dropped `validate_required/2` from `Loans.record/1`; the
    # insert crashed instead of returning the invalid changeset.
    test "a changeset with no agreement id is refused before anything is encrypted" do
      assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
               Loans.record(%{customer_id: @customer, patron_email: "reader@example.com"})

      assert {"can't be blank", _meta} = changeset.errors[:agreement_id]
    end

    # Sabotage: made `AgreementScope.resolve/2` answer the first agreement
    # whatever was set, so both rows were written under one key; the load
    # read both and nothing raised.
    test "a read whose rows span agreements raises instead of answering" do
      {:ok, _loan} = record(@agreement, "reader@example.com")
      {:ok, _loan} = record(@other_agreement, "other@example.com")

      assert_raise DecryptError, fn ->
        AgreementScope.with_agreement(@agreement, fn -> TestRepo.all(SharedLoan) end)
      end
    end

    # Sabotage: made `AgreementScope.resolve/2` answer `{:ok, "agr_default"}`
    # when nothing was set; the raise became an `unknown_key` EncryptError.
    test "outside with_agreement/2 the resolver refuses, and the type raises" do
      assert_raise MissingScopeError, fn ->
        TestRepo.insert!(%SharedLoan{
          customer_id: @customer,
          agreement_id: @agreement,
          patron_email: "reader@example.com"
        })
      end
    end

    test "with_agreement/2 restores the scope it found, nested or not" do
      AgreementScope.with_agreement(@agreement, fn ->
        AgreementScope.with_agreement(@other_agreement, fn ->
          assert {:ok, @other_agreement} = AgreementScope.resolve(:dump, %{})
        end)

        assert {:ok, @agreement} = AgreementScope.resolve(:dump, %{})
      end)

      assert {:error, :no_agreement_in_scope} = AgreementScope.resolve(:load, %{})
    end
  end

  describe "step 6: shred one agreement" do
    # Sabotage: made `Keys.shred_agreement/2` shred through the customer
    # vault; the record assertion went red on `{:error, {:unknown_key, _}}`.
    # Removing the vault restart below left this test green: after a
    # whole-scope shred the answers do not depend on the drain, so this test
    # does not pin the cache's behaviour.
    test "deleting the agreement's key rows ends that agreement and nothing else" do
      {:ok, _loan} = record(@agreement, "reader@example.com")
      {:ok, _loan} = record(@other_agreement, "other@example.com")

      %Account{id: account_id} =
        Scope.wrap(@customer, fn ->
          TestRepo.insert!(%Account{customer_id: @customer, catalog_api_token: "tok-north"})
        end)

      assert [_loan] = Loans.list(@agreement)

      assert {:ok, %Shred{procedure: :scope, versions: [1]}} =
               Keys.shred_agreement(@agreement, drain: :skip)

      assert [] = key_versions(Keys.agreement_table(), ref(@agreement))

      # The runbook's cache drain (encryptor ADR-0005, P3 step 3), done the
      # way the guide offers beside the default wait: restart the vault.
      :ok = stop_supervised(AgreementVault)
      start_supervised!(AgreementVault)

      assert %DecryptError{reason: {:unknown_key, @agreement}} =
               assert_raise(DecryptError, fn -> Loans.list(@agreement) end)

      assert %EncryptError{reason: {:unknown_key, @agreement}} =
               assert_raise(EncryptError, fn -> record(@agreement, "late@example.com") end)

      assert [%SharedLoan{patron_email: "other@example.com"}] = Loans.list(@other_agreement)

      assert %Account{catalog_api_token: "tok-north"} =
               Scope.wrap(@customer, fn -> TestRepo.get!(Account, account_id) end)

      # Step 4 of the runbook: the ciphertext rows still carry the agreement's
      # pseudonym in every header, so they go too.
      assert {:ok, 1} = Loans.forget(@agreement)

      assert [] =
               TestRepo.all(from(l in SharedLoan, where: l.agreement_id == ^@agreement))
    end
  end

  defp record(agreement_id, email) do
    Loans.record(%{customer_id: @customer, agreement_id: agreement_id, patron_email: email})
  end

  defp ref(selector) do
    {:ok, ref} = Encryptor.Envelope.scope_ref(Keys.reference_subkey(), selector)
    ref
  end

  defp key_versions(table, ref) do
    TestRepo.all(from(k in table, where: k.tenant_ref == ^ref, select: k.version))
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
