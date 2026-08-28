defmodule Encryptor.Ecto.MigratorRunTest do
  @moduledoc """
  The engine against real rows: probe, compare-and-swap, batching, checkpoint.

  None of ADR-0002's load-bearing properties is expressible against a mock
  repository. Probe-first idempotence is about what a second run does to rows
  the first one wrote; compare-and-swap is about what the update matches when
  the bytes changed under it; the checkpoint is about a row in a table. So
  every test here writes rows, runs the engine over them, and reads the bytes
  back.

  The legacy format is `Encryptor.Ecto.TestSources.LegacyType`'s: the literal
  `"legacy:"` followed by the reversed plaintext. It is emphatically not
  encryption - it stands in for the host's own working reader, which is the
  only thing ADR-0004 decision 1 lets this package assume about the source
  format.
  """

  use Encryptor.Ecto.RepoCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Encryptor.Ecto.Migrator
  alias Encryptor.Ecto.Migrator.Report
  alias Encryptor.Ecto.Tenant
  alias Encryptor.Ecto.TestEnginePlans
  alias Encryptor.Ecto.TestEngineTypes
  alias Encryptor.Ecto.TestRepo
  alias Encryptor.Ecto.TestSchemas
  alias Encryptor.Ecto.TestTypes.Pan

  @merchant "merchant_7f3"
  @other_merchant "merchant_a19"
  @pan "4111111111111111"

  describe "dry run" do
    # Sabotage: made `swap/5`'s `:dry_run` clause fall through to the write
    # clause - the rehearsal wrote every row, which is the one thing a
    # rehearsal must not do.
    test "classifies every row and writes nothing" do
      id = insert_card(pan: legacy(@pan))

      assert {:ok, report} = Migrator.run(TestEnginePlans.Cards, mode: :dry_run)

      assert report.mode == :dry_run
      assert report.counts.migratable == 1
      assert report.counts.already_target == 0
      assert raw(:cards, id, :pan) == legacy(@pan)
    end

    # Sabotage: made `batch/3`'s `:dry_run` clause record the checkpoint - a
    # later write-mode resume would then start past rows nothing had written.
    test "records no checkpoint" do
      _id = insert_card(pan: legacy(@pan))

      assert {:ok, _report} = Migrator.run(TestEnginePlans.Cards, mode: :dry_run)
      assert checkpoints() == []
    end
  end

  describe "write mode" do
    # Sabotage: dropped the `write_target/2` call and swapped the source bytes
    # in unchanged - the column kept the legacy format and the row read back
    # only because the legacy reader was still in the plan.
    test "rewrites a legacy row into the target format, readable through the type" do
      id = insert_card(pan: legacy(@pan))

      assert {:ok, report} = Migrator.run(TestEnginePlans.Cards, mode: :write)
      assert report.counts.migratable == 1

      bytes = raw(:cards, id, :pan)
      refute bytes == legacy(@pan)

      Tenant.put(@merchant)
      assert %TestSchemas.Card{pan: @pan} = TestRepo.get(TestSchemas.Card, id)
    end

    # Sabotage: made `probe/2` answer `:not_target` unconditionally - the
    # second run re-encrypted every already-migrated row, which is exactly the
    # idempotence decision 5 buys.
    test "a second run finds every row already in the target state" do
      id = insert_card(pan: legacy(@pan))

      assert {:ok, _first} = Migrator.run(TestEnginePlans.Cards, mode: :write)
      written = raw(:cards, id, :pan)

      assert {:ok, second} = Migrator.run(TestEnginePlans.Cards, mode: :write)
      assert second.counts.already_target == 1
      assert second.counts.migratable == 0
      assert raw(:cards, id, :pan) == written
    end

    # Sabotage: dropped the `[_id, nil, _target | _tenant]` clause - a NULL
    # column went to the source reader and was reported undecryptable.
    test "a NULL column is counted and nothing is touched" do
      id = insert_card(pan: nil)

      assert {:ok, report} = Migrator.run(TestEnginePlans.Cards, mode: :write)
      assert report.counts.null == 1
      assert raw(:cards, id, :pan) == nil
    end

    # Sabotage: made `resolver/1` return `:scope` for a column tenant - the
    # dump read the empty process scope and raised instead of encrypting under
    # the row's own merchant.
    test "each row is encrypted under its own tenant" do
      mine = insert_card(pan: legacy(@pan), merchant_id: @merchant)
      theirs = insert_card(pan: legacy(@pan), merchant_id: @other_merchant)

      assert {:ok, report} = Migrator.run(TestEnginePlans.Cards, mode: :write)
      assert report.counts.migratable == 2

      Tenant.put(@other_merchant)
      assert %TestSchemas.Card{pan: @pan} = TestRepo.get(TestSchemas.Card, theirs)

      # The other merchant's row does not open under this one's key: the
      # anti-substitution property, seen from the migrator's side.
      assert_raise Encryptor.Ecto.DecryptError, fn ->
        TestRepo.get(TestSchemas.Card, mine)
      end
    end
  end

  describe "failures" do
    # Sabotage: made `fail/4` return `:ok` for `on_error: :halt` - the pass ran
    # on past a row nobody could read, which decision 11 forbids.
    test "an unreadable row halts the pass and names the row" do
      id = insert_card(pan: "neither format")

      assert {:error, report} = Migrator.run(TestEnginePlans.Cards, mode: :write)

      assert [failure] = report.failures
      assert failure.id == id
      assert failure.field == :pan
      assert failure.schema == TestSchemas.Card
      assert report.failure_count == 1
      refute Report.ok?(report)
    end

    # Sabotage: made the halt arm commit instead of rolling back - the rows
    # before the failing one were written *and* checkpointed, so a resume
    # would step over the row that stopped the pass.
    test "a halted batch discards its writes and its checkpoint" do
      first = insert_card(pan: legacy(@pan))
      _second = insert_card(pan: "neither format")

      assert {:error, _report} = Migrator.run(TestEnginePlans.Cards, mode: :write)

      assert raw(:cards, first, :pan) == legacy(@pan)
      assert checkpoints() == []
    end

    # Sabotage: made `status/1` map `:continue` to `:halt` - the option that
    # exists to find out how many rows are unreadable stopped at the first one.
    test "on_error: :continue finishes the pass and still reports failure" do
      bad = insert_card(pan: "neither format")
      good = insert_card(pan: legacy(@pan))

      assert {:error, report} =
               Migrator.run(TestEnginePlans.Cards, mode: :write, on_error: :continue)

      assert report.failure_count == 1
      assert report.counts.migratable == 1
      assert [%{id: ^bad}] = report.failures
      refute raw(:cards, good, :pan) == legacy(@pan)
    end
  end

  describe "compare-and-swap" do
    # Sabotage: dropped `unchanged/3`'s `where` on the target column - the
    # update matched on the primary key alone and clobbered the row the
    # application had just written, which is the lost update decision 4 exists
    # to prevent.
    test "a row the application rewrote mid-pass is counted, not clobbered" do
      id = insert_card(pan: legacy(@pan))

      TestEngineTypes.race_once(fn -> write_target_state(id, "4222222222222222") end)

      assert {:ok, report} = Migrator.run(TestEnginePlans.Racing, mode: :write)

      assert report.concurrent == 1
      assert report.counts.migratable == 1

      Tenant.put(@merchant)
      assert %TestSchemas.Card{pan: "4222222222222222"} = TestRepo.get(TestSchemas.Card, id)
    end

    # Sabotage: made `concurrent/3` count the row and return `:ok` without
    # re-probing - a row overwritten with bytes nobody can read was reported
    # as a successful concurrent migration.
    test "a lost swap whose row is unreadable is a failure" do
      id = insert_card(pan: legacy(@pan))

      TestEngineTypes.race_once(fn -> write_raw(id, "neither format") end)

      assert {:error, report} = Migrator.run(TestEnginePlans.Racing, mode: :write)
      assert [%{reason: :concurrent_write_unreadable}] = report.failures
    end
  end

  describe "batching and the checkpoint" do
    # Sabotage: made `continue/5` stop after the first batch - the pass
    # reported a green run over the first `batch_size` rows and left the rest
    # legacy.
    test "pages the whole table in batches and calls progress once per batch" do
      ids = for _row <- 1..5, do: insert_card(pan: legacy(@pan))
      parent = self()

      assert {:ok, report} =
               Migrator.run(TestEnginePlans.Cards,
                 mode: :write,
                 batch_size: 2,
                 progress: fn report -> send(parent, {:progress, report.counts.migratable}) end
               )

      assert report.counts.migratable == 5
      assert_received {:progress, 2}
      assert_received {:progress, 4}
      assert_received {:progress, 5}
      assert Enum.all?(ids, fn id -> raw(:cards, id, :pan) != legacy(@pan) end)
    end

    # Sabotage: made `record/3` write the first row's id rather than the
    # batch's last - a resume re-scanned rows it had already written, which is
    # only free because of probe-first and is still not what the cursor means.
    test "the checkpoint records the last id of the last committed batch" do
      ids = for _row <- 1..3, do: insert_card(pan: legacy(@pan))

      assert {:ok, report} = Migrator.run(TestEnginePlans.Cards, mode: :write, batch_size: 2)

      last = List.last(ids)
      assert [row] = checkpoints()
      assert row.last_id == Integer.to_string(last)
      assert row.field == "pan"
      assert row.prefix == ""
      assert row.counts["migratable"] == 3
      assert report.cursors[{TestSchemas.Card, :pan, nil}] == last
    end

    # Sabotage: made `resume_cursor/2` answer `nil` for `resume: true` - the
    # resumed pass re-scanned from the beginning, which is safe but is not
    # what the option asks for and is the whole cost the checkpoint removes.
    test "resume: true starts after the recorded cursor" do
      [first, second, third] = for _row <- 1..3, do: insert_card(pan: legacy(@pan))

      record_checkpoint(TestEnginePlans.Cards, TestSchemas.Card, :pan, "", second)

      assert {:ok, report} = Migrator.run(TestEnginePlans.Cards, mode: :write, resume: true)

      assert report.counts.migratable == 1
      assert raw(:cards, first, :pan) == legacy(@pan)
      assert raw(:cards, second, :pan) == legacy(@pan)
      assert raw(:cards, third, :pan) != legacy(@pan)
    end

    # Sabotage: made `record/3`'s `:none` clause fall through to the write -
    # the documented degraded mode wrote to a table the host said it would not
    # add.
    test "checkpoint: :none rewrites the rows and records nothing" do
      id = insert_card(pan: legacy(@pan))

      assert {:ok, _report} =
               Migrator.run(TestEnginePlans.Cards, mode: :write, checkpoint: :none)

      assert raw(:cards, id, :pan) != legacy(@pan)
      assert checkpoints() == []
    end

    # Sabotage: made `preflight!/2` return `:ok` on the error arm - a missing
    # checkpoint table was discovered on the first batch's insert, mid-pass,
    # instead of before the first row.
    test "a missing checkpoint table is refused, naming the generator" do
      error =
        assert_raise ArgumentError, fn ->
          Migrator.run(TestEnginePlans.Cards, mode: :dry_run, checkpoint_table: "not_a_table")
        end

      assert error.message =~ "mix encryptor.ecto.gen.migration"
      assert error.message =~ "checkpoint: :none"
    end
  end

  describe "scoping a run" do
    # Sabotage: made `fields/2`'s `only` clause ignore the field names - the
    # run rewrote both columns when the operator asked for one.
    test "only: narrows the run to the named field" do
      id = insert_card(pan: legacy(@pan), notes: legacy("a note"))

      assert {:ok, report} =
               Migrator.run(TestEnginePlans.BothColumns,
                 mode: :write,
                 only: [{TestSchemas.Card, [:pan]}]
               )

      assert report.counts.migratable == 1
      assert raw(:cards, id, :pan) != legacy(@pan)
      assert raw(:cards, id, :notes) == legacy("a note")
    end

    # Sabotage: dropped `only_tenants/3`'s `where` - the run visited a tenant
    # the operator had excluded, which for a crypto-shredded tenant is a pass
    # that cannot exit zero.
    test "only_tenants: visits one tenant's rows and leaves the others" do
      mine = insert_card(pan: legacy(@pan), merchant_id: @merchant)
      theirs = insert_card(pan: legacy(@pan), merchant_id: @other_merchant)

      assert {:ok, report} =
               Migrator.run(TestEnginePlans.Cards, mode: :write, only_tenants: [@merchant])

      assert report.counts.migratable == 1
      assert raw(:cards, mine, :pan) != legacy(@pan)
      assert raw(:cards, theirs, :pan) == legacy(@pan)
    end

    # Sabotage: dropped `except_tenants/3`'s `where` - the shredded tenant's
    # rows were visited and the pass could not exit zero.
    test "except_tenants: skips the named tenant" do
      theirs = insert_card(pan: legacy(@pan), merchant_id: @other_merchant)

      assert {:ok, report} =
               Migrator.run(TestEnginePlans.Cards,
                 mode: :write,
                 except_tenants: [@other_merchant]
               )

      assert report.counts.migratable == 0
      assert raw(:cards, theirs, :pan) == legacy(@pan)
    end
  end

  describe "the other tenant strategies" do
    # Sabotage: made `resolver/1` map `:none` to `RowTenant` - a global field
    # asked for a row tenant that is not there and raised instead of
    # encrypting under the vault's single key.
    test "a tenant :none rewrite encrypts under the single-key vault" do
      id = insert_signup(variant_notes: legacy("variant A wins"))

      assert {:ok, report} = Migrator.run(TestEnginePlans.Global, mode: :write)

      assert report.counts.migratable == 1
      assert %TestSchemas.Signup{variant_notes: "variant A wins"} = signup(id)
    end

    # Sabotage: made `pass!/5` ignore `into:` and target the source column -
    # the backfill wrote ciphertext over the plaintext column, which is the
    # expand/contract dance collapsing into a lost column.
    test "into: backfills the binary column and leaves the plaintext one alone" do
      id = insert_signup(email: "buyer@example.com")

      assert {:ok, report} = Migrator.run(TestEnginePlans.Adoption, mode: :write)

      assert report.counts.migratable_unverified == 1
      assert raw(:signups, id, :email) == "buyer@example.com"
      assert %TestSchemas.Signup{email_encrypted: "buyer@example.com"} = signup(id)
    end

    # Sabotage: made `probe/2` read the source column instead of the target -
    # the second adoption pass re-encrypted a row that was already backfilled.
    test "a second adoption pass finds the row already backfilled" do
      _id = insert_signup(email: "buyer@example.com")

      assert {:ok, _first} = Migrator.run(TestEnginePlans.Adoption, mode: :write)
      assert {:ok, second} = Migrator.run(TestEnginePlans.Adoption, mode: :write)

      assert second.counts.already_target == 1
      assert second.counts.migratable == 0
    end
  end

  describe "a target that is a plain Ecto.Type" do
    # Sabotage: made `load_target/2` and `dump_target/2` call the arity-3 form
    # for an arity-1 target - a plain `Ecto.Type` target failed with an
    # UndefinedFunctionError on row one.
    test "is called at arity 1 for both halves of the round trip" do
      id = insert_card(pan: legacy(@pan))

      assert {:ok, report} = Migrator.run(TestEnginePlans.PlainTarget, mode: :write)

      assert report.counts.migratable == 1
      assert raw(:cards, id, :pan) == "plain:" <> @pan
    end

    # Sabotage: made `write_target/2`'s `:error` arm return `{:ok, :error}` -
    # the atom was written into the column as though it were ciphertext.
    test "a target that declines to write is a failure, not a written row" do
      id = insert_card(pan: legacy(@pan))

      assert {:error, report} = Migrator.run(TestEnginePlans.DecliningTarget, mode: :write)

      assert [%{reason: :target_dump_declined}] = report.failures
      assert raw(:cards, id, :pan) == legacy(@pan)
    end

    # Sabotage: made `cursor/4` record the cursor on the halt arm too - the
    # report claimed the pass reached a row whose batch had been rolled back.
    test "a halted pass records no cursor for the field" do
      _id = insert_card(pan: legacy(@pan))

      assert {:error, report} = Migrator.run(TestEnginePlans.DecliningTarget, mode: :write)
      assert report.cursors == %{}
    end
  end

  describe "prefixes" do
    # Sabotage: dropped `query_opts/1`'s `prefix:` - the run read and wrote the
    # default prefix's rows while reporting the other prefix's name, and the
    # prefix the operator asked for was never visited.
    test "a prefixed run visits that prefix's rows and leaves the default's" do
      default = insert_card(pan: legacy(@pan))
      prefixed = insert_card_in_prefix(legacy(@pan))

      assert {:ok, report} =
               Migrator.run(TestEnginePlans.Cards, mode: :write, prefix: "tenant_b")

      assert report.counts.migratable == 1
      assert raw(:cards, default, :pan) == legacy(@pan)
      assert raw_in_prefix(prefixed) != legacy(@pan)
    end

    # Sabotage: dropped the `prefix` component from `checkpoint_key/1` - both
    # prefixes shared one checkpoint row, so the second prefix resumed at the
    # first's cursor and silently skipped every row below it. This is exactly
    # the finding ADR-0002 proposed amendment 6 records.
    test "each prefix gets its own checkpoint row" do
      _default = insert_card(pan: legacy(@pan))
      _prefixed = insert_card_in_prefix(legacy(@pan))

      assert {:ok, _first} = Migrator.run(TestEnginePlans.Cards, mode: :write)

      assert {:ok, _second} =
               Migrator.run(TestEnginePlans.Cards, mode: :write, prefix: "tenant_b")

      assert ["", "tenant_b"] = checkpoints() |> Enum.map(& &1.prefix) |> Enum.sort()
    end
  end

  # -- fixtures -------------------------------------------------------------

  defp legacy(plaintext), do: "legacy:" <> String.reverse(plaintext)

  describe "an unauthenticated source (ADR-0004 decision 3)" do
    # Sabotage: made `migratable/1` answer `:migratable` for every field - the
    # dry run's evidence read exactly like an authenticated source's, which is
    # the false reassurance decision 3a exists to remove.
    test "a dry run counts the acknowledged field apart from the rest" do
      _id = insert_card(pan: legacy(@pan))

      assert {:ok, report} = Migrator.run(TestEnginePlans.Unverified, mode: :dry_run)

      assert report.counts.migratable_unverified == 1
      assert report.counts.migratable == 0
    end

    # Sabotage: made `writable!/4` return `:ok` for the `false`-without-
    # `validate:` case - the pass rewrote rows whose plaintext nothing had
    # authenticated and nothing had checked, permanently.
    test "refuses --mode write without a validator, before reading a row" do
      id = insert_card(pan: legacy(@pan))

      message =
        assert_raise ArgumentError, fn ->
          Migrator.run(TestEnginePlans.Unverified, mode: :write)
        end

      assert Exception.message(message) =~ "Card.pan"
      assert Exception.message(message) =~ "source_authenticated: false"
      assert raw(:cards, id, :pan) == legacy(@pan)
      assert checkpoints() == []
    end

    # Sabotage: made `writable!/4` run over the whole plan rather than the
    # fields `passes!/3` had already narrowed - a run explicitly scoped away
    # from the acknowledged field was refused for it anyway.
    test "the refusal is about the fields in scope, not the whole plan" do
      id = insert_card(pan: legacy(@pan), notes: legacy("chargeback opened"))

      assert_raise ArgumentError, fn -> Migrator.run(TestEnginePlans.Mixed, mode: :write) end

      assert {:ok, report} =
               Migrator.run(TestEnginePlans.Mixed,
                 mode: :write,
                 only: [{TestSchemas.Card, [:notes]}]
               )

      assert report.counts.migratable == 1
      assert report.counts.migratable_unverified == 0
      assert raw(:cards, id, :pan) == legacy(@pan)
    end

    # Sabotage: made `migratable/1` a property of the run rather than of the
    # field - one report could then only say one of the two words, and a plan
    # with both kinds of field lost the distinction it exists to draw.
    test "one report carries both migratable classes" do
      _id = insert_card(pan: legacy(@pan), notes: legacy("chargeback opened"))

      assert {:ok, report} = Migrator.run(TestEnginePlans.Mixed, mode: :dry_run)

      assert report.counts.migratable_unverified == 1
      assert report.counts.migratable == 1
    end

    # Sabotage: made `writable!/4` refuse whenever `source_authenticated:` was
    # `false` - a declared `validate:` bought nothing, and decision 3a's way
    # through the refusal was closed.
    test "a declared validator is what lets the write run" do
      id = insert_card(pan: legacy(@pan))

      assert {:ok, report} = Migrator.run(TestEnginePlans.Validated, mode: :write)

      assert report.counts.migratable_unverified == 1

      Tenant.put(@merchant)
      assert %TestSchemas.Card{pan: @pan} = TestRepo.get(TestSchemas.Card, id)
    end

    # Sabotage: made `load_source/3` ignore `validate/2`'s answer - the row
    # the host's own check rejected was re-encrypted into the target column,
    # which is the laundering decision 3 is written to prevent.
    test "a row the validator rejects is undecryptable and is not written" do
      id = insert_card(pan: legacy("41111111"))

      assert {:error, report} = Migrator.run(TestEnginePlans.Validated, mode: :write)

      assert [%{schema: TestSchemas.Card, field: :pan, reason: :validate_rejected}] =
               report.failures

      assert report.counts.undecryptable == 1
      assert report.counts.migratable_unverified == 0
      assert raw(:cards, id, :pan) == legacy("41111111")
    end

    # Sabotage: made `validate/2` answer `:ok` for any truthy return - a host
    # check that failed with `{:error, :no_hash_column}` read as "valid", and
    # the pass laundered exactly the rows it was declared to catch.
    test "a validator that answers off contract fails the row" do
      id = insert_card(pan: legacy(@pan))

      assert {:error, report} =
               Migrator.run(TestEnginePlans.OffContractValidator, mode: :write)

      assert [%{reason: :validate_off_contract}] = report.failures
      assert raw(:cards, id, :pan) == legacy(@pan)
    end

    # Sabotage: dropped `validate/2`'s rescue - the host's raising check took
    # the pass down with an exception carrying whatever the validator put in
    # it, which is the one place a plaintext could reach a log.
    test "a validator that raises is reported as the module and nothing else" do
      _id = insert_card(pan: legacy(@pan))

      assert {:error, report} = Migrator.run(TestEnginePlans.RaisingValidator, mode: :write)

      assert [%{reason: {:raised, ArgumentError}}] = report.failures
    end
  end

  defp insert_card(attrs) do
    row =
      attrs
      |> Map.new()
      |> Map.put_new(:merchant_id, @merchant)

    {1, [%{id: id}]} = TestRepo.insert_all("cards", [row], returning: [:id])
    id
  end

  defp insert_card_in_prefix(pan) do
    {1, [%{id: id}]} =
      TestRepo.insert_all("cards", [%{merchant_id: @merchant, pan: pan}],
        returning: [:id],
        prefix: "tenant_b"
      )

    id
  end

  defp insert_signup(attrs) do
    row = attrs |> Map.new() |> Map.put_new(:variant, "A")
    {1, [%{id: id}]} = TestRepo.insert_all("signups", [row], returning: [:id])
    id
  end

  defp signup(id) do
    Tenant.put(@merchant)
    TestRepo.get(TestSchemas.Signup, id)
  end

  defp raw(table, id, column) do
    [[value]] =
      TestRepo.all(
        from(r in Atom.to_string(table), where: r.id == ^id, select: [field(r, ^column)])
      )

    value
  end

  defp raw_in_prefix(id) do
    [[value]] =
      TestRepo.all(from(r in "cards", where: r.id == ^id, select: [field(r, :pan)]),
        prefix: "tenant_b"
      )

    value
  end

  defp checkpoints do
    TestRepo.all(
      from(c in "encryptor_ecto_migration_checkpoints",
        order_by: [asc: c.id],
        select: %{
          plan: c.plan,
          schema: c.schema,
          field: c.field,
          prefix: c.prefix,
          last_id: c.last_id,
          counts: c.counts
        }
      )
    )
  end

  defp record_checkpoint(plan, schema, field, prefix, last_id) do
    {1, _returned} =
      TestRepo.insert_all("encryptor_ecto_migration_checkpoints", [
        %{
          plan: inspect(plan),
          schema: inspect(schema),
          field: Atom.to_string(field),
          prefix: prefix,
          last_id: Integer.to_string(last_id),
          counts: %{},
          started_at: DateTime.truncate(DateTime.utc_now(), :second),
          updated_at: DateTime.truncate(DateTime.utc_now(), :second)
        }
      ])

    :ok
  end

  # The row the "application" writes in the middle of the migrator's pass: the
  # target format, written through the ordinary type, which is what the
  # application would have done.
  defp write_target_state(id, plaintext) do
    # The application resolves its tenant from the process scope, the way it
    # does at the edge of a request; the migrator's own row resolver is a
    # different key in a different place and is untouched by this.
    Tenant.put(@merchant)

    params = Pan.init(schema: TestSchemas.Card, field: :pan)
    {:ok, bytes} = Pan.dump(plaintext, &Ecto.Type.dump/2, params)

    write_raw(id, bytes)
  end

  defp write_raw(id, bytes) do
    {1, _returned} =
      TestRepo.update_all(from(r in "cards", where: r.id == ^id), set: [pan: bytes])

    :ok
  end
end
