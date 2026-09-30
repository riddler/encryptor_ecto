defmodule Encryptor.Ecto.RunbookParallelTest do
  @moduledoc """
  The migrate-from-cloak guide's parallel-column exit, at the plan level.

  The host is `Encryptor.Ecto.TestRunbook`'s, the same integrations table the
  in-place walk in `Encryptor.Ecto.RunbookTest` uses, with a
  `<field>_encrypted` column beside each encrypted one. The plan reads each old
  column through its legacy type and writes the new one `into:` its pair, and
  these tests pin what the guide's parallel section says a host sees: the old
  column untouched by the pass, the new one in this package's format,
  `verify/2` reading the new one, a census that reads the new one, and a
  window with nothing to walk back.
  """

  use Encryptor.Ecto.RepoCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Encryptor.Ecto.Migrator
  alias Encryptor.Ecto.Migrator.Census
  alias Encryptor.Ecto.Scope
  alias Encryptor.Ecto.TestRunbook
  alias Encryptor.Ecto.TestRunbook.CutOverIntegration
  alias Encryptor.Ecto.TestRunbook.LegacyIntegration
  alias Encryptor.Ecto.TestRunbook.LegacyVault
  alias Encryptor.Ecto.TestRunbook.ParallelIntegration
  alias Encryptor.Ecto.TestRunbook.ParallelMigration
  alias Encryptor.Ecto.TestRunbook.Vault

  @north "ws_north"
  @south "ws_south"

  @legacy_header <<0x01, 4, "LG">>
  @columns [:client_secret, :access_token, :refresh_token]
  @targets [:client_secret_encrypted, :access_token_encrypted, :refresh_token_encrypted]

  setup do
    Application.put_env(:encryptor_ecto, LegacyVault, key: :binary.copy(<<0x7A>>, 32))

    Application.put_env(:encryptor_ecto, TestRunbook.Keys,
      workspaces: %{@north => :binary.copy(<<0x21>>, 32), @south => :binary.copy(<<0x22>>, 32)},
      subkey: :binary.copy(<<0x23>>, 32),
      derivation_salt: :binary.copy(<<0x24>>, 32)
    )

    on_exit(fn ->
      Application.delete_env(:encryptor_ecto, LegacyVault)
      Application.delete_env(:encryptor_ecto, TestRunbook.Keys)
    end)

    Scope.clear()
    start_supervised!(LegacyVault)
    start_supervised!(Vault)

    :ok
  end

  describe "the dual write" do
    # Sabotage: made `ParallelIntegration`'s `dual_write/1` return the
    # changeset untouched - the new columns stayed NULL.
    test "the host's changeset writes the old column in the legacy format and the new one in ours" do
      Scope.put(@north)

      written =
        %ParallelIntegration{}
        |> ParallelIntegration.changeset(%{
          workspace_id: @north,
          client_secret: "cs-1",
          access_token: "at-1",
          refresh_token: "rt-1"
        })
        |> TestRepo.insert!()

      for column <- @columns,
          do: assert(<<@legacy_header, _rest::binary>> = raw(written.id, column))

      for target <- @targets do
        assert is_binary(raw(written.id, target))
        refute match?(<<@legacy_header, _rest::binary>>, raw(written.id, target))
      end

      assert %CutOverIntegration{
               client_secret: "cs-1",
               access_token: "at-1",
               refresh_token: "rt-1"
             } =
               cut_over(written.id)
    end
  end

  describe "the pass into the new column" do
    # Sabotage: made `Migrator.pass!/5` ignore `into:` (`target_column =
    # field`) - the pass rewrote the old columns in place and the byte-equal
    # comparison failed.
    test "leaves the old column byte for byte, and writes the new one in this package's format" do
      north = seed(@north, "cs-1", "at-1", "rt-1")
      south = seed(@south, "cs-2", "at-2", nil)
      before = for id <- [north, south], column <- @columns, do: raw(id, column)

      assert {:ok, report} = Migrator.run(ParallelMigration, mode: :write)

      assert report.counts == %{
               null: 1,
               already_target: 0,
               migratable: 5,
               migratable_unverified: 0,
               undecryptable: 0
             }

      assert for(id <- [north, south], column <- @columns, do: raw(id, column)) == before

      for id <- [north, south], target <- @targets, raw(id, target) != nil do
        refute match?(<<@legacy_header, _rest::binary>>, raw(id, target))
      end

      # A NULL source leaves its pair NULL.
      assert raw(south, :refresh_token_encrypted) == nil

      Scope.put(@north)

      assert %CutOverIntegration{
               client_secret: "cs-1",
               access_token: "at-1",
               refresh_token: "rt-1"
             } =
               cut_over(north)

      Scope.put(@south)

      assert %CutOverIntegration{client_secret: "cs-2", access_token: "at-2", refresh_token: nil} =
               cut_over(south)
    end

    # Sabotage: made `Migrator.pass!/5` build the target's params for the
    # field rather than its `into:` column - the dual-written bytes no longer
    # loaded under the pass's context and all three were counted migratable.
    test "a row the dual write already wrote is already in the target state and is not rewritten" do
      Scope.put(@north)

      written =
        %ParallelIntegration{}
        |> ParallelIntegration.changeset(%{
          workspace_id: @north,
          client_secret: "cs-1",
          access_token: "at-1",
          refresh_token: "rt-1"
        })
        |> TestRepo.insert!()

      Scope.clear()
      legacy = seed(@north, "cs-2", "at-2", "rt-2")
      targets = Enum.map(@targets, &raw(written.id, &1))

      assert {:ok, report} = Migrator.run(ParallelMigration, mode: :write)
      assert report.counts.already_target == 3
      assert report.counts.migratable == 3
      assert report.concurrent == 0

      assert Enum.map(@targets, &raw(written.id, &1)) == targets
      for target <- @targets, do: assert(is_binary(raw(legacy, target)))
    end
  end

  describe "verification over the new column" do
    # Sabotage: made `verify/2` accept `:migratable` as verified - the
    # unbackfilled table passed the acceptance test.
    test "is red before the pass, and exits 0 after it" do
      _north = seed(@north, "cs-1", "at-1", "rt-1")
      _south = seed(@south, "cs-2", "at-2", "rt-2")

      assert {:error, red} = Migrator.verify(ParallelMigration, sample: :all)
      assert red.counts.migratable == 6

      assert {:ok, _written} = Migrator.run(ParallelMigration, mode: :write)

      assert {:ok, green} = Migrator.verify(ParallelMigration, sample: :all)
      assert green.counts.already_target == 6
      assert green.counts.migratable == 0
      assert green.failure_count == 0
    end
  end

  describe "the census of a parallel plan" do
    # Sabotage: made `Census.rewrite_queries/2` read the field instead of its
    # `into:` column - the format query named "client_secret".
    test "reads the new column, so before the pass it shows no legacy rows at all" do
      _north = seed(@north, "cs-1", "at-1", "rt-1")

      [format | _rest] = Census.queries(ParallelMigration)
      assert format.kind == :format
      assert format.column == "client_secret_encrypted"
      assert %{rows: []} = TestRepo.query!(format.sql)

      # The guide's step 0 query: the same format census over the old column.
      assert %{rows: [[@legacy_header <> _rest, 1]]} =
               TestRepo.query!("""
               SELECT substring("client_secret" from 1 for 4) AS header,
                      count(*) AS rows
               FROM "integrations"
               WHERE "client_secret" IS NOT NULL
               GROUP BY 1
               ORDER BY 2 DESC;
               """)
    end
  end

  describe "the read cut-over, and why there is no reverse plan" do
    # Sabotage: dropped the `column:` pin from `CutOverIntegration`'s
    # `client_secret` - the cut-over read raised `DecryptError`.
    test "the new column reads under the old field names, and the old column still reads as it did" do
      id = seed(@north, "cs-1", "at-1", "rt-1")
      assert {:ok, _written} = Migrator.run(ParallelMigration, mode: :write)

      Scope.put(@north)

      assert %CutOverIntegration{
               client_secret: "cs-1",
               access_token: "at-1",
               refresh_token: "rt-1"
             } =
               cut_over(id)

      # Going back before the drop is reverting the cut-over deploy: the old
      # column was never written by the pass, so the legacy schema reads it.
      assert %LegacyIntegration{
               client_secret: "cs-1",
               access_token: "at-1",
               refresh_token: "rt-1"
             } =
               TestRepo.get(LegacyIntegration, id)
    end

    # Sabotage: made `Migrator.pass!/5` ignore `into:` (`target_column =
    # field`) - the new columns stayed NULL and the cut-over read found none.
    test "after the drop of the old columns the cut-over schema reads every row" do
      id = seed(@north, "cs-1", "at-1", "rt-1")
      assert {:ok, _written} = Migrator.run(ParallelMigration, mode: :write)

      for column <- @columns do
        TestRepo.query!(~s(ALTER TABLE "integrations" DROP COLUMN "#{column}"))
      end

      Scope.put(@north)

      assert %CutOverIntegration{
               client_secret: "cs-1",
               access_token: "at-1",
               refresh_token: "rt-1"
             } =
               cut_over(id)
    end
  end

  # -- helpers --------------------------------------------------------------

  # A row as the host's legacy deploy wrote it, before the dual write existed:
  # the old columns only.
  defp seed(workspace, client_secret, access_token, refresh_token) do
    %LegacyIntegration{
      workspace_id: workspace,
      client_secret: client_secret,
      access_token: access_token,
      refresh_token: refresh_token
    }
    |> TestRepo.insert!()
    |> Map.fetch!(:id)
  end

  # A read through the cut-over schema. A refused decrypt is returned as the
  # exception's module rather than raised, so a read that fails is an
  # assertion failure naming what went wrong rather than a crash before it.
  defp cut_over(id) do
    TestRepo.get(CutOverIntegration, id)
  rescue
    exception in Encryptor.Ecto.DecryptError -> {:raised, exception.__struct__}
  end

  defp raw(id, column) do
    [[value]] =
      TestRepo.all(from(i in "integrations", where: i.id == ^id, select: [field(i, ^column)]))

    value
  end
end
