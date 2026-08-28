defmodule Encryptor.Ecto.Migrator.CLITest do
  @moduledoc """
  The task family's grammar, away from a database.

  ADR-0004 decision 6 fixes the grammar so that the runbook and the tasks
  cannot drift, and every assertion here is about one of the two rules that
  shape it: a flag means exactly one `Encryptor.Ecto.Migrator` option, and a
  flag whose verb has no such option refuses rather than being ignored.

  The exit codes a parse failure earns are asserted at the task level
  (`Mix.Tasks.Encryptor.Ecto.MigrateTest`); what is under test here is what
  the argv becomes and what an operator is told when it cannot become
  anything.
  """

  use ExUnit.Case, async: true

  alias Encryptor.Ecto.Migrator.CLI
  alias Encryptor.Ecto.Migrator.Report
  alias Encryptor.Ecto.TestEnginePlans
  alias Encryptor.Ecto.TestSchemas

  describe "the plan and the mode" do
    # Sabotage: gave `mode/1` a `:dry_run` default for a missing `--mode` -
    # every assertion below still passed and the one that matters, that a
    # missing mode is refused, went green while the task silently rehearsed a
    # pass the operator meant to run.
    test "PLAN and --mode are both required, and --mode has no default" do
      assert {:error, no_plan} = CLI.parse_migrate(["--mode", "write"])
      assert no_plan =~ "PLAN is required"

      assert {:error, no_mode} = CLI.parse_migrate(["MyApp.Plan"])
      assert no_mode =~ "--mode is required and has no default"
    end

    test "the two modes map onto run/2's option, and nothing else does" do
      assert {:ok, {TestEnginePlans.Cards, opts}} =
               CLI.parse_migrate(["Encryptor.Ecto.TestEnginePlans.Cards", "--mode", "dry-run"])

      assert opts[:mode] == :dry_run

      assert {:ok, {_plan, write}} = CLI.parse_migrate(["MyApp.Plan", "--mode", "write"])
      assert write[:mode] == :write

      assert {:error, message} = CLI.parse_migrate(["MyApp.Plan", "--mode", "dry_run"])
      assert message =~ "--mode expects one of"
    end

    test "a fully qualified plan name resolves to the same module" do
      assert {:ok, {TestEnginePlans.Cards, _opts}} =
               CLI.parse_migrate([
                 "Elixir.Encryptor.Ecto.TestEnginePlans.Cards",
                 "--mode",
                 "write"
               ])
    end

    test "two positionals are a usage error rather than a plan and a stray word" do
      assert {:error, message} =
               CLI.parse_migrate(["MyApp.Plan", "MyApp.Other", "--mode", "write"])

      assert message =~ "exactly one PLAN"
    end
  end

  describe "the flags migrate accepts" do
    # Sabotage: made `batch_size/1` accept any integer - `--batch-size 0`
    # parsed, and a pass that visits nothing per transaction reads as a run
    # that found nothing.
    test "--batch-size takes a positive integer and refuses the rest" do
      assert {:ok, {_plan, opts}} = migrate(["--batch-size", "50"])
      assert opts[:batch_size] == 50

      assert {:error, message} = migrate(["--batch-size", "0"])
      assert message =~ "--batch-size expects a positive integer"

      assert {:error, not_a_number} = migrate(["--batch-size", "many"])
      assert not_a_number =~ "--batch-size"
    end

    test "--resume and --no-resume both set the option they name" do
      assert {:ok, {_plan, resumed}} = migrate(["--resume"])
      assert resumed[:resume] == true

      assert {:ok, {_plan, not_resumed}} = migrate(["--no-resume"])
      assert not_resumed[:resume] == false

      assert {:ok, {_plan, absent}} = migrate([])
      refute Keyword.has_key?(absent, :resume)
    end

    # Sabotage: mapped `--no-checkpoint` to `checkpoint: :table` - the flag a
    # host without the table depends on became a no-op, and the pass halted on
    # a preflight the operator had explicitly opted out of.
    test "--no-checkpoint is checkpoint: :none, and --checkpoint is not a flag" do
      assert {:ok, {_plan, opts}} = migrate(["--no-checkpoint"])
      assert opts[:checkpoint] == :none

      assert {:error, message} = migrate(["--checkpoint"])
      assert message =~ "--checkpoint is not a flag"
    end

    # Sabotage: dropped `resumable/1`'s guard - `--resume --no-checkpoint`
    # parsed and the contradiction was left for `run/2` to raise, which is an
    # exit code 2 the task earns for a reason it can state itself.
    test "--resume with --no-checkpoint is refused, not silently reconciled" do
      assert {:error, message} = migrate(["--resume", "--no-checkpoint"])
      assert message =~ "no meaning"
    end

    test "--prefix names one prefix and refuses an empty one" do
      assert {:ok, {_plan, opts}} = migrate(["--prefix", "tenant_b"])
      assert opts[:prefix] == "tenant_b"

      assert {:error, message} = migrate(["--prefix", ""])
      assert message =~ "--prefix expects a schema prefix"
    end

    test "--on-error takes halt or continue" do
      assert {:ok, {_plan, opts}} = migrate(["--on-error", "continue"])
      assert opts[:on_error] == :continue

      assert {:error, message} = migrate(["--on-error", "skip"])
      assert message =~ "--on-error expects one of"
    end

    # Sabotage: made the tenant flags overwrite rather than accumulate - a
    # `--only-tenant a --only-tenant b` pass visited only the last tenant
    # named, so a two-tenant rotation silently migrated one of them.
    test "--only-tenant and --except-tenant accumulate" do
      assert {:ok, {_plan, opts}} =
               migrate([
                 "--only-tenant",
                 "merchant_7f3",
                 "--only-tenant",
                 "merchant_a11",
                 "--except-tenant",
                 "merchant_dead"
               ])

      assert opts[:only_tenants] == ["merchant_7f3", "merchant_a11"]
      assert opts[:except_tenants] == ["merchant_dead"]
    end

    # Sabotage: made `group_only/1` build one entry per pair instead of
    # grouping by schema - `run/2` received the same schema twice and narrowed
    # the plan to whichever entry it read last, so `--only A:pan,A:notes`
    # migrated one column of the two it named.
    test "--only groups fields under their schema, in the order given" do
      assert {:ok, {_plan, opts}} =
               migrate([
                 "--only",
                 "Encryptor.Ecto.TestSchemas.Card:pan,Encryptor.Ecto.TestSchemas.Card:notes"
               ])

      assert opts[:only] == [{TestSchemas.Card, [:pan, :notes]}]
    end

    test "--only refuses a pair it cannot read" do
      assert {:error, message} = migrate(["--only", "MyApp.Card"])
      assert message =~ "--only expects Schema:field pairs"
    end

    test "an unknown flag is a usage error" do
      assert {:error, message} = migrate(["--parallel", "4"])
      assert message =~ "--parallel"
    end
  end

  describe "the flags verify accepts" do
    test "--sample takes all or a positive integer" do
      assert {:ok, {_plan, all}} = verify(["--sample", "all"])
      assert all[:sample] == :all

      assert {:ok, {_plan, some}} = verify(["--sample", "25"])
      assert some[:sample] == 25

      assert {:error, message} = verify(["--sample", "0"])
      assert message =~ "--sample expects `all` or a positive integer"

      assert {:error, words} = verify(["--sample", "lots"])
      assert words =~ "--sample expects `all` or a positive integer"
    end

    test "--prefix is accepted, because a verification of the wrong prefix is worse than none" do
      assert {:ok, {_plan, opts}} = verify(["--prefix", "tenant_b"])
      assert opts[:prefix] == "tenant_b"
    end

    # Sabotage: gave `parse_verify/1` the migrate switch list - `--only-tenant`
    # parsed and was dropped on the floor by `verify/2`, so a verification an
    # operator believed was scoped to one tenant silently reported on all of
    # them. This is the asymmetry ADR-0004 decision 6 forbids the tasks to
    # paper over: the flag has no `verify/2` option behind it, so it refuses.
    test "a migrate-only flag names the verb it belongs to instead of being ignored" do
      for flag <- ["--only-tenant", "--except-tenant", "--on-error", "--only"] do
        assert {:error, message} = verify([flag, "x"])
        assert message =~ "is a `mix encryptor.ecto.migrate` flag"
        assert message =~ "takes only --prefix and --sample"
      end

      assert {:error, batch} = verify(["--batch-size", "10"])
      assert batch =~ "is a `mix encryptor.ecto.migrate` flag"
    end
  end

  describe "the report an operator reads" do
    # Sabotage: rendered a class list written out here instead of
    # `Report.classes/0`, with one class missing - which is what a hardcoded
    # list looks like the day a class is added. The missing class counted
    # against the exit code while printing nowhere, so an operator saw a red
    # pass with every printed count at zero.
    test "prints every class the report knows about" do
      rendered = CLI.render(Report.new(:dry_run))

      for class <- Report.classes() do
        assert rendered =~ "#{class}: 0"
      end

      assert rendered =~ "mode: dry_run"
      assert rendered =~ "concurrent: 0"
      assert rendered =~ "failures: 0"
    end

    # Sabotage: rendered the whole failure map with `inspect/1` rather than
    # its four named fields - the fixture value below reached the rendered
    # line, which is the one place a plaintext would land in an operator's
    # terminal and their shell history. The engine records no value today;
    # this test is what makes rendering-by-field the property rather than the
    # accident.
    test "a failure line names the row and the reason, and carries nothing else" do
      report =
        Report.record_failure(Report.new(:write), %{
          schema: TestSchemas.Card,
          field: :pan,
          id: 17,
          reason: {:load_failed, Encryptor.Ecto.TestSources.LegacyType},
          value: "4111111111111111"
        })

      rendered = CLI.render(report)

      assert rendered =~ "Encryptor.Ecto.TestSchemas.Card.pan"
      assert rendered =~ "id=17"
      assert rendered =~ "reason={:load_failed"
      assert rendered =~ "failures: 1"
      refute rendered =~ "4111111111111111"
    end

    # Sabotage: printed `length(failures)` instead of the bounded report's
    # `failure_count` and dropped the elision line - a pass that failed on
    # 5000 rows reported 100, which is the number the report deliberately
    # stops storing at, not the number of broken rows.
    test "a bounded failure list says how many were not listed" do
      report =
        Enum.reduce(1..(Report.failure_limit() + 3), Report.new(:write), fn id, report ->
          Report.record_failure(report, %{
            schema: TestSchemas.Card,
            field: :pan,
            id: id,
            reason: :undecryptable
          })
        end)

      rendered = CLI.render(report)

      assert rendered =~ "failures: #{Report.failure_limit() + 3}"
      assert rendered =~ "... 3 further failures not listed"
    end
  end

  defp migrate(flags), do: CLI.parse_migrate(["MyApp.Plan", "--mode", "write" | flags])
  defp verify(flags), do: CLI.parse_verify(["MyApp.Plan" | flags])
end
