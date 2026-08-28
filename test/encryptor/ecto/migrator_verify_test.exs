defmodule Encryptor.Ecto.MigratorVerifyTest do
  @moduledoc """
  `verify/2` against real rows: the classification, the arm, and the sample.

  Same reasoning as `Encryptor.Ecto.MigratorRunTest` - none of what verify
  promises is expressible against a mock repository, because every property is
  about what the bytes in a column are and how many rows carry them. The
  legacy format is the same fixture format that suite uses: the literal
  `"legacy:"` followed by the reversed plaintext.

  The load-bearing distinction under test throughout is that verify's arm is
  **stricter** than run's. A table full of readable legacy rows is a green dry
  run and a red verification, and confusing the two would make the acceptance
  test at the end of a rotation (ADR-0004 decision 8, step 6) pass over a
  table that had not been migrated at all.
  """

  use Encryptor.Ecto.RepoCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Encryptor.Ecto.Migrator
  alias Encryptor.Ecto.Migrator.Report
  alias Encryptor.Ecto.TestEnginePlans
  alias Encryptor.Ecto.TestSchemas

  @merchant "merchant_7f3"
  @pan "4111111111111111"

  describe "the arm" do
    # Sabotage: made `verify_result/1` call `Report.ok?/1` instead of
    # `verified?/1` - a table of untouched legacy rows verified green, which
    # is the acceptance test passing over a migration that never ran.
    test "a table of legacy rows is not verified, and says why" do
      _id = insert_card(pan: legacy(@pan))

      assert {:error, report} = Migrator.verify(TestEnginePlans.Cards)

      assert report.mode == :verify
      assert report.counts.migratable == 1
      assert report.counts.already_target == 0
      refute Report.verified?(report)
    end

    # Sabotage: made `verified?/1` ignore `:null` - a column with a NULL row
    # could never verify, so the mixed window would never be declared closed
    # on any table that allows NULLs.
    test "already-migrated and NULL rows verify green" do
      _migrated = insert_card(pan: legacy(@pan))
      _null = insert_card(pan: nil)

      assert {:ok, _run} = Migrator.run(TestEnginePlans.Cards, mode: :write)
      assert {:ok, report} = Migrator.verify(TestEnginePlans.Cards)

      assert report.counts.already_target == 1
      assert report.counts.null == 1
      assert report.counts.migratable == 0
    end

    # Sabotage: made verify run with `on_error: :halt` - the pass stopped at
    # the first unreadable row and reported one, so an operator asking how
    # much of the table was broken got the answer "at least one".
    test "counts every unreadable row rather than stopping at the first" do
      _first = insert_card(pan: "neither format")
      _second = insert_card(pan: "neither format either")

      assert {:error, report} = Migrator.verify(TestEnginePlans.Cards)

      assert report.failure_count == 2
      assert report.counts.undecryptable == 2
    end
  end

  describe "reading only" do
    # Sabotage: dropped `migrate/6`'s `:verify` clause so verification fell
    # through to the write path - the read-only pass rewrote every row it was
    # asked to report on.
    test "writes nothing, on a table it would have plenty to write to" do
      id = insert_card(pan: legacy(@pan))

      assert {:error, _report} = Migrator.verify(TestEnginePlans.Cards)
      assert raw(:cards, id, :pan) == legacy(@pan)
    end

    # Sabotage: put verification back on `batch/3`'s write arm *and* gave
    # `verify_options!/1` a checkpoint table - the read-only pass then opened
    # a transaction and wrote a checkpoint row, and a later `resume: true` run
    # stepped over rows nothing had migrated. Either half alone is inert,
    # which is what the two guards are for: read-only-ness is a property of
    # the mode, and having no checkpoint is a property of the options, and a
    # verification is both.
    test "records no checkpoint and needs no checkpoint table" do
      _id = insert_card(pan: legacy(@pan))

      assert {:error, _report} = Migrator.verify(TestEnginePlans.Cards)
      assert checkpoints() == []
    end

    # Sabotage: made the `:verify` clause dump through the target type before
    # counting - a target that declines to write turned a row that both sides
    # can read into `:undecryptable`, which is a claim about the data rather
    # than about the type.
    test "a target that refuses to dump does not make a readable row undecryptable" do
      _id = insert_card(pan: legacy(@pan))

      assert {:error, report} = Migrator.verify(TestEnginePlans.DecliningTarget)

      assert report.counts.migratable == 1
      assert report.counts.undecryptable == 0
      assert report.failures == []
    end
  end

  describe "sample:" do
    # Sabotage: made `run/3`'s sampled clause fall through to the keyset
    # clause - `sample: 2` read the whole table, so the drift check an
    # operator schedules cost a full scan of every table in the plan.
    test "reads at most that many rows per field" do
      for _row <- 1..5, do: insert_card(pan: legacy(@pan))

      assert {:error, report} = Migrator.verify(TestEnginePlans.Cards, sample: 2)

      assert report.counts.migratable == 2
    end

    # Sabotage: made `sample_query/6` order by the primary key instead of
    # `random()` - the sample became the first n rows in key order, which is
    # exactly the region a partial pass has already migrated, so a half-done
    # table sampled green.
    test "draws from the whole table rather than the head of the key order" do
      migrated = for _row <- 1..20, do: insert_card(pan: legacy(@pan))
      assert {:ok, _run} = Migrator.run(TestEnginePlans.Cards, mode: :write)
      for _row <- 1..20, do: insert_card(pan: legacy(@pan))

      assert length(migrated) == 20

      # A key-ordered sample of 20 over 40 rows would be the 20 migrated ones
      # every time. A random one finds legacy rows with overwhelming odds; the
      # assertion is over ten independent draws so the test does not depend on
      # any single one of them.
      drawn =
        for _attempt <- 1..10 do
          {_arm, report} = Migrator.verify(TestEnginePlans.Cards, sample: 20)
          report.counts.migratable
        end

      assert Enum.any?(drawn, &(&1 > 0))
    end

    # Sabotage: made the sampled clause record a cursor - the report claimed
    # a position in the key order that a random draw does not have, which a
    # resume would then read as a place to start.
    test "records no cursor, because a random draw has no position" do
      for _row <- 1..3, do: insert_card(pan: legacy(@pan))

      assert {:error, report} = Migrator.verify(TestEnginePlans.Cards, sample: 2)
      assert report.cursors == %{}
    end

    # Sabotage: made `sample!/1` default to a fixed row count rather than
    # `:all` - a verification an operator ran as the acceptance test silently
    # checked a slice of a two-million-row table and called it done.
    test "defaults to the whole scope" do
      for _row <- 1..3, do: insert_card(pan: legacy(@pan))

      assert {:error, report} = Migrator.verify(TestEnginePlans.Cards)
      assert report.counts.migratable == 3
    end
  end

  describe "scope" do
    # Sabotage: made `verify_options!/1` drop `prefix:` and always pass `nil` -
    # the verification reported on the default prefix's rows while the
    # operator believed it was checking the other one, which decision 10 calls
    # worse than no verification.
    test "prefix: verifies that prefix's rows and not the default's" do
      _default = insert_card(pan: legacy(@pan))
      prefixed = insert_card_in_prefix(legacy(@pan))

      assert {:ok, _run} =
               Migrator.run(TestEnginePlans.Cards, mode: :write, prefix: "tenant_b")

      assert {:ok, report} = Migrator.verify(TestEnginePlans.Cards, prefix: "tenant_b")
      assert report.counts.already_target == 1
      assert raw_in_prefix(prefixed) != legacy(@pan)

      # The default prefix's row is untouched, so verifying it is still red.
      assert {:error, _default_report} = Migrator.verify(TestEnginePlans.Cards)
    end

    # Sabotage: made `verify_options!/1` accept `@known_options` - `mode:`
    # and `on_error:` were silently accepted and then ignored, so an operator
    # who asked for `mode: :write` got a read-only pass reported as one.
    test "an option verify does not have is refused, naming the ones it does" do
      error =
        assert_raise ArgumentError, fn ->
          Migrator.verify(TestEnginePlans.Cards, mode: :write)
        end

      assert error.message =~ "sample"
      assert error.message =~ "prefix"
    end

    # Sabotage: made `sample!/1` accept any integer - `sample: 0` rendered a
    # `LIMIT 0`, which reads no rows and verifies green over anything.
    test "a sample that is not a positive integer or :all is refused" do
      assert_raise ArgumentError, ~r/sample:/, fn ->
        Migrator.verify(TestEnginePlans.Cards, sample: 0)
      end
    end

    # Sabotage: had `verify/2` name `run/2` in the plan-check message - an
    # operator who called `verify/2` was sent to the other function's docs.
    test "a module that is not a plan is refused, naming verify/2" do
      error =
        assert_raise ArgumentError, fn -> Migrator.verify(TestSchemas.Card) end

      assert error.message =~ "verify/2"
      assert error.message =~ "expects a plan module"
    end
  end

  # -- fixtures -------------------------------------------------------------

  defp legacy(plaintext), do: "legacy:" <> String.reverse(plaintext)

  defp insert_card(attrs) do
    row = attrs |> Map.new() |> Map.put_new(:merchant_id, @merchant)
    {1, [%{id: id}]} = TestRepo.insert_all("cards", [row], returning: [:id])
    id
  end

  describe "an unauthenticated source (ADR-0004 decision 3a)" do
    # Sabotage: made `migratable/1` answer `:migratable` in the `:verify` arm
    # only - the acceptance test's own evidence said "migratable" about rows
    # nothing authenticated, which is the report claiming a verification that
    # never happened.
    test "counts the acknowledged field's rows apart, and is not verified" do
      _id = insert_card(pan: legacy(@pan))

      assert {:error, report} = Migrator.verify(TestEnginePlans.Unverified)

      assert report.counts.migratable_unverified == 1
      assert report.counts.migratable == 0
      refute Report.verified?(report)
    end

    # Sabotage: made the `:verify` arm skip `validate/2` - a row the host's
    # own check rejects verified as merely migratable, so the acceptance test
    # disagreed with the write the operator would run next.
    test "a row the validator rejects is undecryptable here too" do
      _id = insert_card(pan: legacy("41111111"))

      assert {:error, report} = Migrator.verify(TestEnginePlans.Validated)

      assert [%{reason: :validate_rejected}] = report.failures
      assert report.counts.migratable_unverified == 0
    end

    # Sabotage: made `verify_options!/1` accept `mode:` - the read-only
    # function grew the option whose refusal is the whole reason a plan with
    # an unvalidated acknowledgement can still be inspected.
    test "needs no mode, so an unwritable field can still be inspected" do
      _id = insert_card(pan: legacy(@pan))

      assert_raise ArgumentError, fn -> Migrator.run(TestEnginePlans.Unverified, mode: :write) end
      assert {:error, _report} = Migrator.verify(TestEnginePlans.Unverified)
    end
  end

  defp insert_card_in_prefix(pan) do
    {1, [%{id: id}]} =
      TestRepo.insert_all("cards", [%{merchant_id: @merchant, pan: pan}],
        returning: [:id],
        prefix: "tenant_b"
      )

    id
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
    TestRepo.all(from(c in "encryptor_ecto_migration_checkpoints", select: c.id))
  end
end
