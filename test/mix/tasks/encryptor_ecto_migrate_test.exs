defmodule Mix.Tasks.Encryptor.Ecto.MigrateTest do
  @moduledoc """
  `mix encryptor.ecto.migrate` against real rows: the exit codes.

  The grammar is `Encryptor.Ecto.Migrator.CLITest`'s. What is under test here
  is the half a runbook step depends on - "check it worked" needs something to
  check - and it is only expressible against a pass that ran: 0 is a completed
  pass with no failures, 1 is a pass that found something, and 2 is a request
  that never became a pass at all.

  The three codes are asserted through `main/1` rather than `run/1` because
  `run/1` sets the code through `System.at_exit/1`, which a test process
  cannot observe without ending the suite.
  """

  use Encryptor.Ecto.RepoCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Encryptor.Ecto.Migrate

  @merchant "merchant_7f3"
  @pan "4111111111111111"
  @plan "Encryptor.Ecto.TestEnginePlans.Cards"

  describe "exit 0" do
    # Sabotage: made `run_pass/1` return 1 on the `{:ok, report}` arm - every
    # green rotation looked like a failed one, and step 5 of the runbook could
    # never be signed off.
    test "a write pass that rewrote every row and failed on none" do
      _id = insert_card(pan: legacy(@pan))

      assert {0, output} = migrate([@plan, "--mode", "write"])

      assert output =~ "mode: write"
      assert output =~ "migratable: 1"
      assert output =~ "failures: 0"
    end

    test "a dry run over readable legacy rows, which is a rehearsal that found no problem" do
      _id = insert_card(pan: legacy(@pan))

      assert {0, output} = migrate([@plan, "--mode", "dry-run"])
      assert output =~ "mode: dry_run"
    end
  end

  describe "exit 1" do
    # Sabotage: made the `{:error, report}` arm return 0 - a dry run that
    # found undecryptable rows exited clean, and ADR-0004 decision 8's step 4
    # ("resolve every undecryptable row before proceeding") had nothing to
    # act on.
    test "a dry run that found an undecryptable row" do
      _id = insert_card(pan: "neither format")

      assert {1, output} = migrate([@plan, "--mode", "dry-run", "--on-error", "continue"])

      assert output =~ "undecryptable: 1"
      assert output =~ "failures: 1"
      assert output =~ "Encryptor.Ecto.TestSchemas.Card.pan"
    end

    test "the report still prints everything the pass did before it halted" do
      _broken = insert_card(pan: "neither format")

      assert {1, output} = migrate([@plan, "--mode", "write"])
      assert output =~ "failures: 1"
    end
  end

  describe "exit 2" do
    # Sabotage: let the ArgumentError out of `run_pass/1` - `mix` reported the
    # crash and exited 1, which is the code that means "the pass ran and found
    # something" about a pass that never started.
    test "a module that is not a plan" do
      assert {2, output} = migrate(["Encryptor.Ecto.TestSchemas.Card", "--mode", "write"])
      assert output =~ "exports no `__plan__/0`"
    end

    test "a missing mode, before anything is read" do
      assert {2, output} = migrate([@plan])
      assert output =~ "--mode is required"
    end

    # Sabotage: mapped `--only-scope` onto `run/2`'s `:except_scopes` - a
    # scope filter against a global rewrite stopped raising, and a request
    # that names one scope quietly migrated every other one instead.
    test "a run that cannot start - a scope filter against a rewrite with no scope" do
      assert {2, output} =
               migrate([
                 "Encryptor.Ecto.TestEnginePlans.Global",
                 "--mode",
                 "write",
                 "--only-scope",
                 @merchant
               ])

      assert output =~ "Encryptor.Ecto.TestSchemas.Signup"
    end

    # ADR-0006 decision 7: the old filter flags are gone with no alias, and
    # the strict parse refuses them before a row is read. A flag that parsed
    # and mapped onto nothing would narrow nothing, so a write run meant for
    # one scope would rewrite them all.
    #
    # Sabotage: added `only_tenant: [:string, :keep]` and
    # `except_tenant: [:string, :keep]` to `@migrate_switches` - both parsed,
    # mapped onto no option, and the pass rewrote the row and exited 0.
    test "the pre-rename filter flags, refused before any row is read" do
      id = insert_card(pan: legacy(@pan))

      for stale <- ["--only-tenant", "--except-tenant"] do
        assert {2, output} = migrate([@plan, "--mode", "write", stale, @merchant])
        assert output =~ stale
      end

      assert raw_pan(id) == legacy(@pan)
    end
  end

  defp migrate(argv) do
    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn ->
            send(self(), {:exit_code, Migrate.main(argv)})
          end)

        send(self(), {:stdout, stdout})
      end)

    assert_received {:exit_code, code}
    assert_received {:stdout, stdout}

    {code, stdout <> stderr}
  end

  defp legacy(plaintext), do: "legacy:" <> String.reverse(plaintext)

  defp raw_pan(id) do
    %{rows: [[pan]]} = TestRepo.query!("SELECT pan FROM cards WHERE id = $1", [id])
    pan
  end

  defp insert_card(attrs) do
    row = attrs |> Map.new() |> Map.put_new(:merchant_id, @merchant)
    {1, [%{id: id}]} = TestRepo.insert_all("cards", [row], returning: [:id])
    id
  end
end
