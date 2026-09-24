defmodule Encryptor.Ecto.MigratorFoldedIndexTest do
  @moduledoc """
  A blind index folded into the rewrite pass (ADR-0004's Note of 2026-09-24,
  answering its open question Q1), against real rows.

  The properties are about what lands in a column and how many times a row is
  decrypted to get it there, so every test writes rows, runs the engine, and
  reads the bytes back. The index a folded pass writes is compared against
  the value `Encryptor.Ecto.BlindIndex.put_index/3` computes for the same
  plaintext under the same scope, because "the same function as the
  changeset helper" is the claim the fold rests on.
  """

  use Encryptor.Ecto.RepoCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Encryptor.Ecto.BlindIndex
  alias Encryptor.Ecto.Migrator
  alias Encryptor.Ecto.Scope
  alias Encryptor.Ecto.TestEnginePlans
  alias Encryptor.Ecto.TestSchemas.Cardholder
  alias Encryptor.Ecto.TestSources.CountingLegacyType

  @merchant "merchant_7f3"
  @other_merchant "merchant_a19"
  @email "Bob@Example.COM "

  describe "a folded index" do
    # Sabotage: made `index_set/2`'s folding clause answer `{:ok, []}` - the
    # ciphertext was rewritten and the index column stayed NULL, which is the
    # two-pass path with the option silently ignored.
    test "is written by the rewrite pass alone, with put_index/3's value" do
      id = insert_cardholder(email: legacy(@email))

      assert {:ok, report} = Migrator.run(TestEnginePlans.FoldedIndex, mode: :write)
      assert report.counts.migratable == 1

      assert raw(id, :email_index) == put_index_value(@merchant, @email)

      Scope.put(@merchant)
      assert %Cardholder{email: @email} = TestRepo.get(Cardholder, id)
    end

    # Sabotage: made `migrate/6` load the source a second time before
    # `index_set/2` - two decrypts per row, the cost of the two-pass path the
    # fold exists to halve, and the count read four for two rows.
    test "costs one decrypt per row" do
      _mine = insert_cardholder(email: legacy(@email))
      _theirs = insert_cardholder(email: legacy(@email), merchant_id: @other_merchant)
      before = CountingLegacyType.loads()

      assert {:ok, report} = Migrator.run(TestEnginePlans.FoldedIndex, mode: :write)
      assert report.counts.migratable == 2

      assert CountingLegacyType.loads() - before == 2
    end

    # Sabotage: made `Encryptor.Ecto.Migrator`'s `index/3` keep the field's
    # declared `:process` strategy - the migrator never sets the process scope,
    # so every row's index raised `MissingScopeError` and the pass halted.
    test "keys each row's index under that row's own scope" do
      mine = insert_cardholder(email: legacy(@email))
      theirs = insert_cardholder(email: legacy(@email), merchant_id: @other_merchant)

      assert {:ok, _report} = Migrator.run(TestEnginePlans.FoldedIndex, mode: :write)

      assert raw(mine, :email_index) == put_index_value(@merchant, @email)
      assert raw(theirs, :email_index) == put_index_value(@other_merchant, @email)
      refute raw(mine, :email_index) == raw(theirs, :email_index)
    end

    # Sabotage: made `swap/5`'s `:dry_run` clause fall through to the write
    # clause - the rehearsal wrote the index and the ciphertext.
    test "is computed and discarded by a dry run" do
      id = insert_cardholder(email: legacy(@email))
      before = CountingLegacyType.loads()

      assert {:ok, report} = Migrator.run(TestEnginePlans.FoldedIndex, mode: :dry_run)
      assert report.counts.migratable == 1

      assert raw(id, :email_index) == nil
      assert raw(id, :email) == legacy(@email)
      assert CountingLegacyType.loads() - before == 1
    end

    # Sabotage: dropped the `rescue` from `index_set/2` - the vault's refusal
    # escaped `run/2` as an exception instead of a row in the report, and the
    # batch's earlier work went with it.
    test "records a failure to compute it against the index column, and writes nothing" do
      id = insert_cardholder(nickname: legacy("ace"))

      assert {:error, report} = Migrator.run(TestEnginePlans.UnderivableIndex, mode: :write)

      assert [%{field: :nickname, id: ^id, reason: {:blind_index, :nickname_index, reason}}] =
               report.failures

      assert {:raised, module} = reason
      assert is_atom(module)
      assert raw(id, :nickname) == legacy("ace")
      assert raw(id, :nickname_index) == nil
    end
  end

  describe "the default two-pass path" do
    # Sabotage: made `Encryptor.Ecto.Migrator`'s `index/3` fold the field's
    # sole declaration when the spec names none - the default pass wrote an
    # index nobody asked it for, which is decision 9's separation gone.
    test "rewrites the ciphertext and leaves the index column alone" do
      id = insert_cardholder(email: legacy(@email))

      assert {:ok, report} = Migrator.run(TestEnginePlans.UnfoldedIndex, mode: :write)
      assert report.counts.migratable == 1

      refute raw(id, :email) == legacy(@email)
      assert raw(id, :email_index) == nil
    end
  end

  # -- helpers ----------------------------------------------------------------

  # `LegacyType`'s format: the literal prefix, then the reversed plaintext.
  defp legacy(plaintext), do: "legacy:" <> String.reverse(plaintext)

  defp put_index_value(scope, email) do
    Scope.put(scope)

    %Cardholder{}
    |> Ecto.Changeset.cast(%{email: email}, [:email])
    |> BlindIndex.put_index(:email, :email_index)
    |> Ecto.Changeset.fetch_change!(:email_index)
  after
    Scope.clear()
  end

  defp insert_cardholder(attrs) do
    row = attrs |> Map.new() |> Map.put_new(:merchant_id, @merchant)
    {1, [%{id: id}]} = TestRepo.insert_all("cardholders", [row], returning: [:id])
    id
  end

  defp raw(id, column) do
    [[value]] =
      TestRepo.all(from(r in "cardholders", where: r.id == ^id, select: [field(r, ^column)]))

    value
  end
end
