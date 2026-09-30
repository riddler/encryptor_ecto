defmodule Encryptor.Ecto.RunbookParallelWalkTest do
  @moduledoc """
  The migrate-from-cloak guide's parallel-column exit, walked step by step.

  `Encryptor.Ecto.RunbookTest` walks the in-place exit and
  `Encryptor.Ecto.RunbookParallelTest` pins the parallel shape at the level of
  the plan. This file is the rehearsal between them: each describe block is
  one of the guide's "Parallel step" sections, 0 to 8, run against the same
  host - `Encryptor.Ecto.TestRunbook`'s integrations table, one secret column
  and two token columns under one legacy key, each with its
  `<field>_encrypted` pair - and each test asserts what that section says the
  host sees. A step whose guide text and whose test disagree is a defect in
  one of the two.

  Steps 0 to 3 and 7 to 8 are host deploys; what of them a test can check is
  checked here, against the fixture's host modules written the way the guide
  tells a host to write them.
  """

  use Encryptor.Ecto.RepoCase, async: false

  import Ecto.Query, only: [from: 2]
  import Encryptor.Ecto.TestTelemetry
  import ExUnit.CaptureIO

  alias Encryptor.Ecto.Migrator
  alias Encryptor.Ecto.Migrator.Census
  alias Encryptor.Ecto.Scope
  alias Encryptor.Ecto.TestRunbook
  alias Encryptor.Ecto.TestRunbook.CutOverIntegration
  alias Encryptor.Ecto.TestRunbook.LegacyIntegration
  alias Encryptor.Ecto.TestRunbook.LegacyVault
  alias Encryptor.Ecto.TestRunbook.Migration
  alias Encryptor.Ecto.TestRunbook.ParallelIntegration
  alias Encryptor.Ecto.TestRunbook.ParallelMigration
  alias Encryptor.Ecto.TestRunbook.Vault
  alias Mix.Tasks.Encryptor.Ecto.Migrate
  alias Mix.Tasks.Encryptor.Ecto.Verify

  @north "ws_north"
  @south "ws_south"
  # A workspace with rows and no key material: step 1's gap.
  @unprovisioned "ws_unprovisioned"

  @legacy_header <<0x01, 4, "LG">>
  @columns [:client_secret, :access_token, :refresh_token]
  @targets [:client_secret_encrypted, :access_token_encrypted, :refresh_token_encrypted]
  @pairs Enum.zip(@columns, @targets)

  @plan "Encryptor.Ecto.TestRunbook.ParallelMigration"

  # Step 8's trap, as a host would write it by mistake: the old field name
  # back on the new column through `source:`, without `column:`. The declared
  # context column is derived from the field, `"client_secret"`, while the
  # pass wrote every row under `"client_secret_encrypted"`.
  defmodule UnpinnedIntegration do
    @moduledoc false

    use Ecto.Schema

    schema "integrations" do
      field(:workspace_id, :string)

      field(:client_secret, Encryptor.Ecto.TestRunbook.Final.Binary,
        source: :client_secret_encrypted
      )
    end
  end

  setup context do
    # Stands in for the host's runtime configuration, as in the in-place walk.
    Application.put_env(:encryptor_ecto, LegacyVault, key: :binary.copy(<<0x7A>>, 32))
    Application.put_env(:encryptor_ecto, TestRunbook.Keys, keys(%{}))

    on_exit(fn ->
      Application.delete_env(:encryptor_ecto, LegacyVault)
      Application.delete_env(:encryptor_ecto, TestRunbook.Keys)
    end)

    Scope.clear()

    # The release-task test starts its own vaults, the way the guide tells a
    # host to; every other step runs in an application that started them.
    unless context[:unstarted] do
      start_supervised!(LegacyVault)
      start_supervised!(Vault)
    end

    :ok
  end

  describe "parallel step 0: finish or abandon any in-flight legacy rotation" do
    # Sabotage: made `Census.rewrite_queries/2` read the field instead of its
    # `into:` column - the plan's format query named "client_secret", the
    # old column.
    test "the plan's census reads the new column; the guide's query over the old one shows the legacy format alone" do
      _north = seed(@north, "cs-1", "at-1", "rt-1")
      _south = seed(@south, "cs-2", "at-2", "rt-2")
      _written = dual_write(@north, "cs-3", "at-3", "rt-3")

      # The census a parallel plan renders reads the new column, so before
      # step 5 it shows only the row the dual write wrote, and no legacy one.
      [format | _rest] = Census.queries(ParallelMigration)
      assert format.kind == :format
      assert format.column == "client_secret_encrypted"
      assert %{rows: [[header, 1]]} = TestRepo.query!(format.sql)
      refute header == @legacy_header

      # The guide's step 0 query is "the same format query over the old
      # column": the in-place plan's format census of that column, verbatim.
      [in_place | _rest] = Census.queries(Migration)
      assert in_place.sql == old_column_census("client_secret")

      # Expected: the prefixes of the legacy format and nothing else.
      for column <- @columns do
        assert %{rows: [[@legacy_header, 3]]} =
                 TestRepo.query!(old_column_census(Atom.to_string(column)))
      end
    end
  end

  describe "parallel step 1: provision vault key material for every scope" do
    # Sabotage: made `Pass.write_target/2`'s rescue report `:load_failed` -
    # the provisioning gap read exactly like an unreadable legacy row.
    test "a workspace with no key material fails at its own row, as a vault error, until it is provisioned" do
      _north = seed(@north, "cs-1", "at-1", "rt-1")
      orphan = seed(@unprovisioned, "cs-9", "at-9", "rt-9")

      assert {:error, report} =
               Migrator.run(ParallelMigration, mode: :dry_run, on_error: :continue)

      assert report.counts.migratable == 3
      assert report.counts.undecryptable == 3

      assert report.failures |> Enum.map(& &1.field) |> Enum.sort() ==
               Enum.sort(@columns)

      for failure <- report.failures do
        assert failure.id == orphan
        assert failure.reason == {:raised, Encryptor.Ecto.EncryptError}
      end

      # "Go back and fill it": the same dry run, once the workspace has key
      # material, is clean.
      provision(@unprovisioned, <<0x25>>)

      assert {:ok, clean} = Migrator.run(ParallelMigration, mode: :dry_run)
      assert clean.counts.migratable == 6
      assert clean.counts.undecryptable == 0
    end
  end

  describe "parallel step 2: both libraries and the new columns" do
    # Sabotage: made `Encryptor.Ecto.Binary.load/3`'s `nil` clause answer
    # `{:ok, ""}` - the step 3 schema read an empty secret where the new
    # column is NULL.
    test "every new column is NULL on every row, and the step 3 schema reads such a row" do
      north = seed(@north, "cs-1", "at-1", "rt-1")
      south = seed(@south, "cs-2", nil, "rt-2")

      for id <- [north, south], target <- @targets, do: assert(raw(id, target) == nil)

      for column <- @columns, raw(north, column) != nil do
        assert <<@legacy_header, _rest::binary>> = raw(north, column)
      end

      Scope.put(@north)

      assert %ParallelIntegration{
               client_secret: "cs-1",
               access_token: "at-1",
               refresh_token: "rt-1",
               client_secret_encrypted: nil,
               access_token_encrypted: nil,
               refresh_token_encrypted: nil
             } = TestRepo.get(ParallelIntegration, north)
    end
  end

  describe "parallel step 3: the dual write" do
    # Sabotage: made `ParallelIntegration`'s `dual_write/1` return the
    # changeset untouched - the new columns stayed NULL.
    test "a new row carries both columns, the old in the legacy format and the new in ours, and reads are unchanged" do
      written = dual_write(@north, "cs-1", "at-1", "rt-1")

      for {column, target} <- @pairs do
        assert <<@legacy_header, _rest::binary>> = raw(written, column)
        assert is_binary(raw(written, target))
        refute match?(<<@legacy_header, _rest::binary>>, raw(written, target))
      end

      Scope.put(@north)

      # Reads stay on the old fields, through the legacy types.
      assert %LegacyIntegration{
               client_secret: "cs-1",
               access_token: "at-1",
               refresh_token: "rt-1"
             } = TestRepo.get(LegacyIntegration, written)

      assert %ParallelIntegration{
               client_secret_encrypted: "cs-1",
               access_token_encrypted: "at-1",
               refresh_token_encrypted: "rt-1"
             } = TestRepo.get(ParallelIntegration, written)
    end

    # Sabotage: made `ParallelIntegration`'s `dual_write/1` return the
    # changeset untouched - the updated field's pair stayed NULL.
    test "an update writes the changed field's pair; a write past the changeset leaves its pair behind" do
      id = seed(@north, "cs-1", "at-1", "rt-1")

      Scope.put(@north)

      _updated =
        ParallelIntegration
        |> TestRepo.get(id)
        |> ParallelIntegration.changeset(%{refresh_token: "rt-2"})
        |> TestRepo.update!()

      assert %ParallelIntegration{
               refresh_token: "rt-2",
               refresh_token_encrypted: "rt-2",
               client_secret_encrypted: nil,
               access_token_encrypted: nil
             } = TestRepo.get(ParallelIntegration, id)

      # An `update_all` is a write the dual write does not see: the old
      # column moves and its pair still holds the value before it.
      {1, _returned} =
        TestRepo.update_all(from(i in "integrations", where: i.id == ^id),
          set: [refresh_token: LegacyVault.encrypt("rt-3")]
        )

      assert %ParallelIntegration{refresh_token: "rt-3", refresh_token_encrypted: "rt-2"} =
               TestRepo.get(ParallelIntegration, id)

      # The pass backfills the NULL pairs but not the stale one, and step 6
      # finds the stale pair already in the target state: found here or not
      # at all.
      Scope.clear()
      assert {:ok, _written} = Migrator.run(ParallelMigration, mode: :write)
      assert {:ok, _verified} = Migrator.verify(ParallelMigration, sample: :all)

      Scope.put(@north)

      assert %ParallelIntegration{
               refresh_token: "rt-3",
               refresh_token_encrypted: "rt-2",
               client_secret_encrypted: "cs-1",
               access_token_encrypted: "at-1"
             } = TestRepo.get(ParallelIntegration, id)
    end
  end

  describe "parallel step 4: write the plan and rehearse it" do
    # Sabotage: made `Pass.swap/5`'s `:dry_run` clause never match - the
    # rehearsal wrote the new columns, and the NULL ones stopped being NULL.
    test "exit 0 with undecryptable: 0; dual-written rows count already_target, every other value migratable, and nothing is written" do
      _north = seed(@north, "cs-1", "at-1", nil)
      south = seed(@south, "cs-2", "at-2", "rt-2")
      written = dual_write(@north, "cs-3", "at-3", "rt-3")
      targets = Enum.map(@targets, &raw(written, &1))

      {code, output} = migrate([@plan, "--mode", "dry-run"])

      assert code == 0

      assert output ==
               """
               mode: dry_run
               null: 1
               already_target: 3
               migratable: 5
               migratable_unverified: 0
               undecryptable: 0
               concurrent: 0
               failures: 0
               """

      for target <- @targets, do: assert(raw(south, target) == nil)
      assert Enum.map(@targets, &raw(written, &1)) == targets
    end

    # The release task is the in-place step's, with this plan's name.
    @tag :unstarted
    # Sabotage: made the fixture `Vault.init/1` build its provider over an
    # empty workspace map instead of the configured one - the vault started
    # inside the callback held no key for the row's scope, and the dry run
    # answered `:error`.
    test "the release task's shape, both vaults started inside the callback, rehearses clean" do
      _id = seed_without_vault(@north)

      {:ok, {status, report}, _apps} =
        Ecto.Migrator.with_repo(TestRepo, fn _repo ->
          {:ok, legacy} = LegacyVault.start_link()
          {:ok, _vault} = Vault.start_link()

          try do
            Migrator.run(ParallelMigration, mode: :dry_run)
          after
            GenServer.stop(legacy)
            :ok = Vault.stop()
          end
        end)

      assert status == :ok
      assert report.counts.migratable == 3
      assert report.counts.undecryptable == 0
    end
  end

  describe "parallel step 5: write the new columns" do
    # Sabotage: made `Migrator.pass!/5` ignore `into:` (`target_column =
    # field`) - the pass rewrote the old columns in place and the byte-equal
    # comparison failed.
    test "exit 0 and failures: 0; every old column byte for byte, a NULL source leaves its pair NULL, and the integrity query catches up" do
      north = seed(@north, "cs-1", "at-1", "rt-1")
      south = seed(@south, "cs-2", "at-2", nil)
      before = for id <- [north, south], column <- @columns, do: raw(id, column)

      assert integrity("client_secret") == %{
               "rows" => 2,
               "source_non_null" => 2,
               "target_non_null" => 0,
               "target_empty" => 0
             }

      {code, output} = migrate([@plan, "--mode", "write"])

      assert code == 0

      assert output ==
               """
               mode: write
               null: 1
               already_target: 0
               migratable: 5
               migratable_unverified: 0
               undecryptable: 0
               concurrent: 0
               failures: 0
               """

      assert for(id <- [north, south], column <- @columns, do: raw(id, column)) == before
      assert raw(south, :refresh_token_encrypted) == nil

      for column <- @columns do
        assert %{"target_empty" => 0} = counts = integrity(Atom.to_string(column))
        assert counts["target_non_null"] == counts["source_non_null"]
      end
    end

    # Sabotage: made `Pass.batch/3`'s halt arm record the checkpoint and
    # commit instead of rolling back - the cursor named the row the pass
    # halted on.
    test "a halted pass leaves its committed batches, and a resume finishes the rest" do
      first = seed(@north, "cs-1", "at-1", "rt-1")
      bad = seed(@north, "cs-2", "at-2", "rt-2")
      corrupt!(bad, :client_secret)

      assert {:error, halted} = Migrator.run(ParallelMigration, mode: :write, batch_size: 1)
      assert [%{id: ^bad}] = halted.failures
      assert is_binary(raw(first, :client_secret_encrypted))
      assert raw(bad, :client_secret_encrypted) == nil
      assert checkpoint_cursor(:client_secret) == Integer.to_string(first)

      # Resolve the row - here, by writing it again through the application,
      # whose dual write puts both columns.
      Scope.put(@north)

      _fixed =
        from(i in ParallelIntegration,
          where: i.id == ^bad,
          select: struct(i, [:id, :workspace_id])
        )
        |> TestRepo.one!()
        |> ParallelIntegration.changeset(%{client_secret: "cs-2"})
        |> TestRepo.update!()

      Scope.clear()

      assert {:ok, resumed} =
               Migrator.run(ParallelMigration, mode: :write, batch_size: 1, resume: true)

      assert resumed.failure_count == 0
      assert {:ok, _verified} = Migrator.verify(ParallelMigration, sample: :all)
    end
  end

  describe "parallel step 6: verify over the new columns" do
    setup :capture_legacy_load

    # Sabotage: made `Report.verified?/1` accept `:migratable` - the
    # unbackfilled table verified green.
    test "exit 1 before the pass; exit 0 after it, every row already_target or null, and no legacy_load" do
      _north = seed(@north, "cs-1", "at-1", "rt-1")
      _south = seed(@south, "cs-2", "at-2", nil)

      {red, red_output} = verify([@plan, "--sample", "all"])
      assert red == 1
      assert red_output =~ "migratable: 5\n"

      assert {:ok, _written} = Migrator.run(ParallelMigration, mode: :write)

      # Drained here so the assertion below is about the verification only.
      flush_legacy_load()

      {code, output} = verify([@plan, "--sample", "all"])

      assert code == 0

      assert output ==
               """
               mode: verify
               null: 1
               already_target: 5
               migratable: 0
               migratable_unverified: 0
               undecryptable: 0
               concurrent: 0
               failures: 0
               """

      # There is no legacy_load count in this shape: the new types carry no
      # `legacy:`.
      refute_received {:telemetry, [:encryptor_ecto, :legacy_load], _measurements, _metadata}
    end
  end

  describe "parallel step 7: reads cut over, in one deploy" do
    # Sabotage: made `Encryptor.Ecto.Binary`'s `declared_value/4` ignore a
    # pinned value - the cut-over read derived `"client_secret"` and raised
    # `DecryptError`.
    test "every read succeeds and equals the old column, and the kept dual write keeps the way back open" do
      north = seed(@north, "cs-1", "at-1", "rt-1")
      south = seed(@south, "cs-2", "at-2", nil)
      assert {:ok, _written} = Migrator.run(ParallelMigration, mode: :write)

      for {id, workspace} <- [{north, @north}, {south, @south}] do
        Scope.put(workspace)
        old = TestRepo.get(LegacyIntegration, id)
        assert %CutOverIntegration{} = new = cut_over(id)

        for column <- @columns, do: assert(Map.fetch!(new, column) == Map.fetch!(old, column))
      end

      # A write after the cut-over still goes through the dual write, so the
      # old column stays current and reverting the deploy reads it.
      Scope.put(@north)

      _updated =
        ParallelIntegration
        |> TestRepo.get(north)
        |> ParallelIntegration.changeset(%{access_token: "at-2"})
        |> TestRepo.update!()

      assert %CutOverIntegration{access_token: "at-2"} = cut_over(north)
      assert %LegacyIntegration{access_token: "at-2"} = TestRepo.get(LegacyIntegration, north)
    end

    # Sabotage: made `Encryptor.Ecto.Binary`'s `derive_column/1` answer one
    # fixed string - the unpinned declaration and the pass agreed on the
    # context column and the read succeeded.
    test "a DecryptError on a verified row is a declaration whose column is not the one the pass wrote under" do
      id = seed(@north, "cs-1", "at-1", "rt-1")
      assert {:ok, _written} = Migrator.run(ParallelMigration, mode: :write)
      assert {:ok, _verified} = Migrator.verify(ParallelMigration, sample: :all)

      Scope.put(@north)

      assert_raise Encryptor.Ecto.DecryptError, fn -> TestRepo.get(UnpinnedIntegration, id) end
    end
  end

  describe "parallel step 8: the old columns and the legacy library dropped" do
    # Sabotage: made `Migrator.pass!/5` ignore `into:` (`target_column =
    # field`) - the new columns stayed NULL and the cut-over read found none.
    test "with the old columns gone, the old field names read every row through the pinned column" do
      north = seed(@north, "cs-1", "at-1", "rt-1")
      south = seed(@south, "cs-2", "at-2", nil)
      assert {:ok, _written} = Migrator.run(ParallelMigration, mode: :write)

      for column <- @columns do
        TestRepo.query!(~s(ALTER TABLE "integrations" DROP COLUMN "#{column}"))
      end

      Scope.put(@north)

      assert %CutOverIntegration{
               client_secret: "cs-1",
               access_token: "at-1",
               refresh_token: "rt-1"
             } = cut_over(north)

      Scope.put(@south)

      assert %CutOverIntegration{client_secret: "cs-2", access_token: "at-2", refresh_token: nil} =
               cut_over(south)

      # Without `column:` the declared context is derived from the field
      # name, and every row is refused.
      assert_raise Encryptor.Ecto.DecryptError, fn -> TestRepo.get(UnpinnedIntegration, south) end
    end
  end

  # -- helpers --------------------------------------------------------------

  defp keys(extra) do
    [
      workspaces:
        Map.merge(
          %{@north => :binary.copy(<<0x21>>, 32), @south => :binary.copy(<<0x22>>, 32)},
          extra
        ),
      subkey: :binary.copy(<<0x23>>, 32),
      derivation_salt: :binary.copy(<<0x24>>, 32)
    ]
  end

  # Step 1's fix: the workspace gets key material, and the vault, which reads
  # its configuration when it starts, is restarted to pick it up.
  defp provision(workspace, byte) do
    Application.put_env(
      :encryptor_ecto,
      TestRunbook.Keys,
      keys(%{workspace => :binary.copy(byte, 32)})
    )

    :ok = stop_supervised(Vault)
    start_supervised!(Vault)
  end

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

  # The same row, written while the legacy vault is up just for the write:
  # the release-task test needs the vault down when the pass runs.
  defp seed_without_vault(workspace) do
    {:ok, legacy} = LegacyVault.start_link()

    try do
      seed(workspace, "cs-1", "at-1", "rt-1")
    after
      GenServer.stop(legacy)
    end
  end

  # A row as the step 3 deploy writes it: through the host's changeset.
  defp dual_write(workspace, client_secret, access_token, refresh_token) do
    Scope.wrap(workspace, fn ->
      %ParallelIntegration{}
      |> ParallelIntegration.changeset(%{
        workspace_id: workspace,
        client_secret: client_secret,
        access_token: access_token,
        refresh_token: refresh_token
      })
      |> TestRepo.insert!()
      |> Map.fetch!(:id)
    end)
  end

  defp corrupt!(id, column) do
    <<head::binary-size(20), byte, tail::binary>> = raw(id, column)
    flipped = head <> <<Bitwise.bxor(byte, 0xFF)>> <> tail

    {1, _returned} =
      TestRepo.update_all(from(i in "integrations", where: i.id == ^id), set: [{column, flipped}])

    :ok
  end

  # The guide's step 0 query, verbatim but for the table and the column.
  defp old_column_census(column) do
    """
    SELECT substring("#{column}" from 1 for 4) AS header,
           count(*) AS rows
    FROM "integrations"
    WHERE "#{column}" IS NOT NULL
    GROUP BY 1
    ORDER BY 2 DESC;\
    """
  end

  # Step 5's integrity query, as the plan's census renders it for one field.
  defp integrity(field) do
    query =
      ParallelMigration
      |> Census.queries()
      |> Enum.find(&(&1.kind == :integrity and Atom.to_string(&1.field) == field))

    %{columns: columns, rows: [row]} = TestRepo.query!(query.sql)
    Map.new(Enum.zip(columns, row))
  end

  # A read through the cut-over schema. A refused decrypt is returned as the
  # exception's module rather than raised, so a read that fails is an
  # assertion failure naming what went wrong rather than a crash before it.
  defp cut_over(id) do
    TestRepo.get(CutOverIntegration, id)
  rescue
    exception in Encryptor.Ecto.DecryptError -> {:raised, exception.__struct__}
  end

  defp flush_legacy_load do
    receive do
      {:telemetry, [:encryptor_ecto, :legacy_load], _measurements, _metadata} ->
        flush_legacy_load()
    after
      0 -> :ok
    end
  end

  defp checkpoint_cursor(field) do
    %{rows: [[last_id]]} =
      TestRepo.query!(
        "SELECT last_id FROM encryptor_ecto_migration_checkpoints WHERE field = $1",
        [Atom.to_string(field)]
      )

    last_id
  end

  defp migrate(argv), do: with_io(fn -> Migrate.main(argv) end)

  defp verify(argv), do: with_io(fn -> Verify.main(argv) end)

  defp raw(id, column) do
    [[value]] =
      TestRepo.all(from(i in "integrations", where: i.id == ^id, select: [field(i, ^column)]))

    value
  end
end
