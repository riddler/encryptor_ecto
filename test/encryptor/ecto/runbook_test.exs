defmodule Encryptor.Ecto.RunbookTest do
  @moduledoc """
  The migrate-from-cloak runbook, walked step by step against one host.

  `docs/guides/migrate-from-cloak.md` tells a host what to run and what it
  should see. Each describe block below is one of its steps, run against
  `Encryptor.Ecto.TestRunbook`'s integrations table - one secret column and
  two token columns, all written under a single legacy key - and each test
  asserts what the guide says the host sees. A step whose guide text and
  whose test disagree is a defect in one of the two.

  Steps 0 and 2 are host deploy state; what of them can be checked is checked
  here (nothing is written, and the legacy types still read every row).
  """

  use Encryptor.Ecto.RepoCase, async: false

  import Ecto.Query, only: [from: 2]
  import Encryptor.Ecto.BlindIndex, only: [put_index: 3, where_eq: 3]
  import Encryptor.Ecto.TestTelemetry
  import ExUnit.CaptureIO

  alias Encryptor.Ecto.Migrator
  alias Encryptor.Ecto.Migrator.Census
  alias Encryptor.Ecto.Tenant
  alias Encryptor.Ecto.TestRunbook
  alias Encryptor.Ecto.TestRunbook.FinalIntegration
  alias Encryptor.Ecto.TestRunbook.Integration
  alias Encryptor.Ecto.TestRunbook.LegacyIntegration
  alias Encryptor.Ecto.TestRunbook.LegacyVault
  alias Encryptor.Ecto.TestRunbook.Migration
  alias Encryptor.Ecto.TestRunbook.Rollback
  alias Encryptor.Ecto.TestRunbook.Vault
  alias Mix.Tasks.Encryptor.Ecto.Migrate

  @north "ws_north"
  @south "ws_south"
  # A workspace with rows and no key material: step 1's gap.
  @unprovisioned "ws_unprovisioned"

  @legacy_header <<0x01, 4, "LG">>
  @columns [:client_secret, :access_token, :refresh_token]

  setup context do
    # Stands in for the host's runtime configuration: the legacy key, and the
    # new vault's per-workspace material. Both vaults read them when they
    # start, never at compile time.
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

    Tenant.clear()

    # The release-task step starts its own vaults, the way the guide tells a
    # host to; every other step runs in an application that started them.
    unless context[:unstarted] do
      start_supervised!(LegacyVault)
      start_supervised!(Vault)
    end

    :ok
  end

  describe "step 2: both libraries in the tree, schemas on the legacy types" do
    # Sabotage: made the fixture's `LegacyVault.decrypt/1` decline every
    # envelope - the legacy schema stopped reading its own rows.
    test "the legacy types write and read every column, and nothing is in the new format" do
      id = seed(@north, "cs-1", "at-1", "rt-1")

      for column <- @columns, do: assert(<<@legacy_header, _rest::binary>> = raw(id, column))

      assert %LegacyIntegration{
               client_secret: "cs-1",
               access_token: "at-1",
               refresh_token: "rt-1"
             } =
               TestRepo.get(LegacyIntegration, id)
    end
  end

  describe "step 3: the type modules switched over, with legacy: set" do
    setup :capture_legacy_load

    # Sabotage: dropped the `legacy:` option from `TestRunbook.Encrypted.String`
    # - the token columns raised `DecryptError` on the first read of a legacy
    # row.
    test "every legacy row still reads, and each legacy read is counted per column" do
      id = seed(@north, "cs-1", "at-1", "rt-1")

      Tenant.put(@north)

      assert %Integration{client_secret: "cs-1", access_token: "at-1", refresh_token: "rt-1"} =
               TestRepo.get(Integration, id)

      # The metadata is the table and the column and nothing else.
      for column <- ["client_secret", "access_token", "refresh_token"] do
        assert_received {:telemetry, [:encryptor_ecto, :legacy_load], %{count: 1},
                         %{table: "integrations", column: ^column} = metadata}

        assert metadata |> Map.keys() |> Enum.sort() == [:column, :table]
      end
    end

    # Sabotage: dropped `legacy:` from `TestRunbook.Encrypted.String` - the
    # read before the write raised `DecryptError` on the legacy row.
    test "a legacy value written back is written in the new format" do
      id = seed(@north, "cs-1", "at-1", "rt-1")

      Tenant.put(@north)

      integration = TestRepo.get(Integration, id)
      _updated = integration |> Ecto.Changeset.change(refresh_token: "rt-2") |> TestRepo.update!()

      refute match?(<<@legacy_header, _rest::binary>>, raw(id, :refresh_token))
      # Readable without the legacy reader: the column really is in the new
      # format, not merely readable through the fallback.
      assert "rt-2" ==
               TestRepo.one(
                 from(i in FinalIntegration, where: i.id == ^id, select: i.refresh_token)
               )
    end

    # Sabotage: made `load_arm/2` answer a missing tenant with a default one -
    # the legacy reader answered and no exception was raised.
    test "a missing tenant is loud, and the legacy reader is not asked" do
      id = seed(@north, "cs-1", "at-1", "rt-1")

      assert_raise Encryptor.Ecto.MissingTenantError, fn -> TestRepo.get(Integration, id) end
      refute_received {:telemetry, [:encryptor_ecto, :legacy_load], _measurements, _metadata}
    end
  end

  describe "step 4: the dry run" do
    # Sabotage: made `swap/5`'s `:dry_run` clause never match - the rehearsal
    # rewrote the good rows, and the raw bytes stopped matching.
    test "with on_error: :continue it censuses every row, names the unreadable one, and writes nothing" do
      good = seed(@north, "cs-1", "at-1", nil)
      bad = seed(@south, "cs-2", "at-2", "rt-2")
      corrupt!(bad, :client_secret)
      before = Enum.map(@columns, &raw(good, &1))

      assert {:error, report} = Migrator.run(Migration, mode: :dry_run, on_error: :continue)

      assert report.counts == %{
               null: 1,
               already_target: 0,
               migratable: 4,
               migratable_unverified: 0,
               undecryptable: 1
             }

      assert [failure] = report.failures

      assert failure == %{
               schema: Integration,
               field: :client_secret,
               id: bad,
               reason: :load_failed
             }

      assert Enum.map(@columns, &raw(good, &1)) == before
    end

    # Sabotage: dropped the `reason=` part of `CLI.failure_lines/1` - the
    # printed failure line no longer matched the guide's.
    test "the mix form prints the counts, the failure line, and exits 1" do
      bad = seed(@south, "cs-2", "at-2", "rt-2")
      corrupt!(bad, :client_secret)

      {code, output} =
        migrate([
          "Encryptor.Ecto.TestRunbook.Migration",
          "--mode",
          "dry-run",
          "--on-error",
          "continue"
        ])

      assert code == 1

      assert output ==
               """
               mode: dry_run
               null: 0
               already_target: 0
               migratable: 2
               migratable_unverified: 0
               undecryptable: 1
               concurrent: 0
               failures: 1
                 Encryptor.Ecto.TestRunbook.Integration.client_secret id=#{bad} reason=:load_failed
               """
    end

    # Step 1's "If it differs": a workspace with no key material is a vault
    # error on the write side, not a failed decrypt of the legacy row.
    # Sabotage: made `write_target/2`'s rescue report `:load_failed` - the
    # vault gap read exactly like an unreadable legacy row.
    test "a workspace with no key material fails at its own row, as a vault error" do
      _good = seed(@north, "cs-1", "at-1", "rt-1")
      orphan = seed(@unprovisioned, "cs-9", "at-9", "rt-9")

      assert {:error, report} = Migrator.run(Migration, mode: :dry_run)

      assert [%{id: ^orphan, field: :client_secret, reason: reason}] = report.failures
      refute reason == :load_failed
      assert {:raised, Encryptor.Ecto.EncryptError} = reason
    end
  end

  describe "step 5: the write pass" do
    # Sabotage: made `filter_tenants/2` ignore the tenant filters - the
    # excluded workspace's first row halted the pass.
    test "rewrites all three columns under each row's own workspace, excluding a tenant" do
      north = seed(@north, "cs-1", "at-1", "rt-1")
      south = seed(@south, "cs-2", "at-2", "rt-2")
      orphan = seed(@unprovisioned, "cs-9", "at-9", "rt-9")

      assert {:ok, report} =
               Migrator.run(Migration, mode: :write, except_tenants: [@unprovisioned])

      assert report.counts.migratable == 6
      assert report.failure_count == 0

      for id <- [north, south], column <- @columns do
        refute match?(<<@legacy_header, _rest::binary>>, raw(id, column))
      end

      for column <- @columns, do: assert(<<@legacy_header, _rest::binary>> = raw(orphan, column))

      Tenant.put(@south)

      assert %FinalIntegration{client_secret: "cs-2", access_token: "at-2", refresh_token: "rt-2"} =
               TestRepo.get(FinalIntegration, south)
    end

    # Sabotage: made `batch/3`'s halt arm record the checkpoint and commit
    # instead of rolling back - the cursor named the row the pass halted on.
    test "a halted pass leaves its committed batches, and a resume finishes the rest" do
      first = seed(@north, "cs-1", "at-1", "rt-1")
      bad = seed(@north, "cs-2", "at-2", "rt-2")
      corrupt!(bad, :client_secret)

      assert {:error, halted} = Migrator.run(Migration, mode: :write, batch_size: 1)
      assert [%{id: ^bad}] = halted.failures
      refute match?(<<@legacy_header, _rest::binary>>, raw(first, :client_secret))

      # The batch it halted in was rolled back with its cursor: the recorded
      # cursor is the last committed batch's, so a resume visits the bad row.
      assert checkpoint_cursor(:client_secret) == Integer.to_string(first)

      # Resolve the row - here, by writing it again through the application.
      Tenant.put(@north)

      _fixed =
        from(i in FinalIntegration, where: i.id == ^bad, select: struct(i, [:id, :workspace_id]))
        |> TestRepo.one!()
        |> Ecto.Changeset.change(client_secret: "cs-2")
        |> TestRepo.update!()

      Tenant.clear()

      assert {:ok, resumed} = Migrator.run(Migration, mode: :write, batch_size: 1, resume: true)
      assert resumed.failure_count == 0
      assert {:ok, _verified} = Migrator.verify(Migration, sample: :all)
    end

    # Sabotage: removed both refusals - `CLI.resumable/1`'s and `run/2`'s -
    # and the pass started, from no cursor, and exited 0.
    test "--resume with --no-checkpoint is refused before a pass starts" do
      _id = seed(@north, "cs-1", "at-1", "rt-1")

      stderr =
        capture_io(:stderr, fn ->
          {code, _output} =
            migrate([
              "Encryptor.Ecto.TestRunbook.Migration",
              "--mode",
              "write",
              "--resume",
              "--no-checkpoint"
            ])

          send(self(), {:code, code})
        end)

      assert_received {:code, 2}
      assert stderr =~ "no checkpoint to resume from"
    end
  end

  describe "step 6: verification over the whole scope" do
    # Sabotage: made `verify/2` accept `:migratable` as verified - a table of
    # readable legacy rows passed the acceptance test.
    # Sabotage: removed `target_params/3`'s `legacy: nil` - the target's
    # legacy reader answered every probe and the verification went green over
    # an unmigrated table.
    test "readable legacy rows are a green dry run and a red verification" do
      _id = seed(@north, "cs-1", "at-1", "rt-1")

      assert {:ok, _dry} = Migrator.run(Migration, mode: :dry_run)
      assert {:error, red} = Migrator.verify(Migration, sample: :all)
      assert red.counts.migratable == 3

      assert {:ok, _written} = Migrator.run(Migration, mode: :write)
      assert {:ok, green} = Migrator.verify(Migration, sample: :all)
      assert green.counts.already_target == 3
      assert green.counts.migratable == 0
    end
  end

  describe "step 7: the unkeyed lookup column replaced" do
    # Sabotage: made `put_index/3` return the changeset untouched - the
    # backfill wrote no index and the unindexed count stayed at two.
    test "backfilled in tenant scope, the keyed index finds every row, and the hash can go" do
      north = seed(@north, "cs-1", "at-shared", "rt-1")
      south = seed(@south, "cs-2", "at-shared", "rt-2")
      assert {:ok, _written} = Migrator.run(Migration, mode: :write)

      # Before the backfill both of the guide's checks name the gap.
      assert unindexed() == 2
      assert per_tenant_gaps() |> Enum.sort() == [@north, @south]

      backfill(@north)
      backfill(@south)

      # A row written from step 7's changeset carries both columns, which is
      # what keeps the switchover gapless until the drop.
      Tenant.put(@north)

      written =
        %Integration{}
        |> Integration.changeset(%{workspace_id: @north, access_token: "at-new"})
        |> TestRepo.insert!()

      assert is_binary(written.access_token_hash) and is_binary(written.access_token_index)
      Tenant.clear()

      assert unindexed() == 0
      assert per_tenant_gaps() == []

      # The unkeyed column equates the two workspaces' rows with no key at all;
      # the keyed index does not.
      assert raw(north, :access_token_hash) == raw(south, :access_token_hash)
      refute raw(north, :access_token_index) == raw(south, :access_token_index)

      TestRepo.query!(~s(ALTER TABLE "integrations" DROP COLUMN "access_token_hash"))

      Tenant.put(@south)

      assert %FinalIntegration{id: ^south} =
               FinalIntegration |> where_eq(:access_token, "at-shared") |> TestRepo.one()
    end
  end

  describe "step 8: legacy: gone" do
    # Sabotage: made `legacy_arm_or_raise!/4`'s no-legacy arm answer `nil` -
    # the unmigrated row read as empty instead of raising.
    test "every migrated row reads without the legacy reader, and an unmigrated one does not" do
      migrated = seed(@north, "cs-1", "at-1", "rt-1")
      assert {:ok, _written} = Migrator.run(Migration, mode: :write)
      missed = seed(@north, "cs-2", "at-2", "rt-2")

      Tenant.put(@north)

      assert %FinalIntegration{client_secret: "cs-1"} = TestRepo.get(FinalIntegration, migrated)
      assert_raise Encryptor.Ecto.DecryptError, fn -> TestRepo.get(FinalIntegration, missed) end
    end
  end

  describe "the reverse plan" do
    # Sabotage: swapped the reverse plan's `to:` back to the new types - the
    # pass found every row already in the target state and wrote nothing.
    # Sabotage: made `dump_target/2`'s arity-1 arm return the plaintext -
    # the rolled-back columns held no legacy envelope.
    test "walks the table back into the legacy format, readable by the legacy types" do
      id = seed(@north, "cs-1", "at-1", "rt-1")
      assert {:ok, _forward} = Migrator.run(Migration, mode: :write)

      assert {:ok, rehearsal} = Migrator.run(Rollback, mode: :dry_run)
      assert rehearsal.counts.migratable == 3

      assert {:ok, _back} = Migrator.run(Rollback, mode: :write)

      for column <- @columns, do: assert(<<@legacy_header, _rest::binary>> = raw(id, column))

      assert %LegacyIntegration{
               client_secret: "cs-1",
               access_token: "at-1",
               refresh_token: "rt-1"
             } =
               TestRepo.get(LegacyIntegration, id)
    end
  end

  describe "watching a pass without a key" do
    # Sabotage: narrowed `Census`'s `@header_bytes` to 1 - the legacy group's
    # header was one byte, not the envelope's four.
    test "the format census separates the two formats on four bytes" do
      _north = seed(@north, "cs-1", "at-1", "rt-1")
      _south = seed(@south, "cs-2", "at-2", "rt-2")
      assert {:ok, _written} = Migrator.run(Migration, mode: :write, only_tenants: [@north])

      [format | _rest] = Census.queries(Migration)
      assert format.kind == :format
      assert format.column == "client_secret"

      %{rows: rows} = TestRepo.query!(format.sql)

      # One row per format, one of each: the legacy header and the new one.
      assert [[_first, 1], [_second, 1]] = rows

      assert [@legacy_header] ==
               for([header, _count] <- rows, header == @legacy_header, do: header)
    end

    # Sabotage: dropped the integrity query from `Census.rewrite_queries/2` -
    # no "nothing became NULL or empty" heading was rendered.
    test "the rendered script covers every column the plan names" do
      script = Migration |> Census.queries() |> Census.script()

      for column <- @columns do
        assert script =~ ~s("integrations"."#{column}": format census, grouped on 4 bytes)
        assert script =~ ~s("integrations"."#{column}": nothing became NULL or empty)
        assert script =~ ~s("integrations"."#{column}": rotation progress for one tenant)
      end
    end
  end

  describe "a release task that starts only the repository" do
    @describetag :unstarted

    # What `Ecto.Migrator.with_repo/2` gives a release task: the repository,
    # and none of the host's supervision tree - so neither vault is running.
    # Sabotage: made `EctoType.adapted/4`'s rescue report `:load_failed` -
    # the raise from the unstarted legacy vault lost its module.
    test "with neither vault started, every row is reported unreadable" do
      _id = seed_without_vault(@north)

      {:ok, {status, report}, _apps} =
        Ecto.Migrator.with_repo(TestRepo, fn _repo ->
          Migrator.run(Migration, mode: :dry_run, on_error: :continue)
        end)

      assert status == :error
      assert report.counts.undecryptable == 3
      assert Enum.all?(report.failures, &(&1.reason == {:raised, ArgumentError}))
    end

    # Sabotage: made `Pass.migratable/1` answer `:migratable_unverified` for
    # every field - the clean pass counted no migratable row.
    test "starting both vaults inside the callback, from configuration, makes it a clean pass" do
      _id = seed_without_vault(@north)

      {:ok, {status, report}, _apps} =
        Ecto.Migrator.with_repo(TestRepo, fn _repo ->
          {:ok, legacy} = LegacyVault.start_link()
          {:ok, _vault} = Vault.start_link()

          try do
            Migrator.run(Migration, mode: :dry_run)
          after
            GenServer.stop(legacy)
            :ok = Vault.stop()
          end
        end)

      assert status == :ok
      assert report.counts.migratable == 3
    end
  end

  # -- helpers --------------------------------------------------------------

  # A row as the host's legacy deploy wrote it: through the legacy types, with
  # the unkeyed hash beside the access token.
  defp seed(workspace, client_secret, access_token, refresh_token) do
    %LegacyIntegration{
      workspace_id: workspace,
      client_secret: client_secret,
      access_token: access_token,
      refresh_token: refresh_token,
      access_token_hash: access_token && :crypto.hash(:sha256, access_token)
    }
    |> TestRepo.insert!()
    |> Map.fetch!(:id)
  end

  # The same row, written while the legacy vault is up just for the write:
  # the release-task tests need the vault down when the pass runs.
  defp seed_without_vault(workspace) do
    {:ok, legacy} = LegacyVault.start_link()

    try do
      seed(workspace, "cs-1", "at-1", "rt-1")
    after
      GenServer.stop(legacy)
    end
  end

  defp corrupt!(id, column) do
    <<head::binary-size(20), byte, tail::binary>> = raw(id, column)
    flipped = head <> <<Bitwise.bxor(byte, 0xFF)>> <> tail

    {1, _returned} =
      TestRepo.update_all(from(i in "integrations", where: i.id == ^id), set: [{column, flipped}])

    :ok
  end

  # Step 7.3: a decrypt-and-recompute pass over one workspace's rows, in that
  # workspace's scope. `put_index/3` computes from a change, so the loaded
  # value is put back as one.
  defp backfill(workspace) do
    Tenant.wrap(workspace, fn ->
      from(i in Integration, where: i.workspace_id == ^workspace)
      |> TestRepo.all()
      |> Enum.each(fn integration ->
        integration
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.force_change(:access_token, integration.access_token)
        |> put_index(:access_token, :access_token_index)
        |> TestRepo.update!()
      end)
    end)
  end

  # The guide's two step 7 checks, verbatim but for the table and columns.
  defp unindexed do
    %{rows: [[count]]} =
      TestRepo.query!("""
      SELECT count(*) AS unindexed
      FROM "integrations"
      WHERE "access_token" IS NOT NULL
        AND "access_token_index" IS NULL;
      """)

    count
  end

  defp per_tenant_gaps do
    %{rows: rows} =
      TestRepo.query!("""
      SELECT "workspace_id",
             count(*) FILTER (WHERE "access_token_index" IS NOT NULL) AS indexed,
             count(*) FILTER (WHERE "access_token" IS NOT NULL) AS encrypted
      FROM "integrations"
      GROUP BY 1
      HAVING count(*) FILTER (WHERE "access_token_index" IS NOT NULL)
           < count(*) FILTER (WHERE "access_token" IS NOT NULL);
      """)

    Enum.map(rows, &hd/1)
  end

  defp checkpoint_cursor(field) do
    %{rows: [[last_id]]} =
      TestRepo.query!(
        "SELECT last_id FROM encryptor_ecto_migration_checkpoints WHERE field = $1",
        [Atom.to_string(field)]
      )

    last_id
  end

  defp migrate(argv) do
    {code, output} = with_io(fn -> Migrate.main(argv) end)
    {code, output}
  end

  defp raw(id, column) do
    [[value]] =
      TestRepo.all(from(i in "integrations", where: i.id == ^id, select: [field(i, ^column)]))

    value
  end
end
