defmodule Mix.Tasks.Encryptor.Ecto.VerifyTest do
  @moduledoc """
  `mix encryptor.ecto.verify` against real rows: the stricter arm.

  The distinction under test is the one an acceptance test depends on. A table
  of readable legacy rows is a green `mix encryptor.ecto.migrate --mode
  dry-run` and a **red** verification, because the question this verb asks is
  whether the rotation is finished rather than whether it can proceed
  (ADR-0002 decision 10). Exit 0 over `--sample all` is what closes the mixed
  window in ADR-0004 decision 8's step 6, so exiting 0 over a table nothing
  migrated would be the evidence saying the opposite of what happened.
  """

  use Encryptor.Ecto.RepoCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Encryptor.Ecto.Migrate
  alias Mix.Tasks.Encryptor.Ecto.Verify

  @merchant "merchant_7f3"
  @pan "4111111111111111"
  @plan "Encryptor.Ecto.TestEnginePlans.Cards"

  # Sabotage: made `run_pass/1` route verify through `Report.ok?/1` by
  # returning 0 on `{:error, report}` when the report had no failures - a
  # table of untouched legacy rows verified green, which is the acceptance
  # test at the end of a rotation passing over a migration that never ran.
  test "a table of readable legacy rows exits 1, where a dry run exits 0" do
    _id = insert_card(pan: legacy(@pan))

    assert {0, _dry_run} =
             capture(fn ->
               Migrate.main([@plan, "--mode", "dry-run"])
             end)

    assert {1, output} = verify([@plan])

    assert output =~ "mode: verify"
    assert output =~ "migratable: 1"
  end

  test "the same table after a write pass exits 0" do
    _id = insert_card(pan: legacy(@pan))
    _null = insert_card(pan: nil)

    assert {0, _written} =
             capture(fn -> Migrate.main([@plan, "--mode", "write"]) end)

    assert {0, output} = verify([@plan, "--sample", "all"])

    assert output =~ "already_target: 1"
    assert output =~ "null: 1"
  end

  # Sabotage: dropped `sample: N` from the options `parse_verify/1` builds -
  # the flag parsed and never reached `verify/2`, so the bounded drift check
  # an operator schedules read every row of every table in the plan. (The
  # `--sample all` half of the same mutation is inert here, because `:all` is
  # the default; `Encryptor.Ecto.Migrator.CLITest` is where it goes red.)
  test "--sample N reads at most that many rows per field" do
    for _row <- 1..5, do: insert_card(pan: legacy(@pan))

    assert {1, output} = verify([@plan, "--sample", "2"])
    assert output =~ "migratable: 2"
  end

  test "a migrate-only flag exits 2 and says which verb owns it" do
    assert {2, output} = verify([@plan, "--only-tenant", @merchant])

    assert output =~ "is a `mix encryptor.ecto.migrate` flag"
    assert output =~ "takes only --prefix and --sample"
  end

  defp verify(argv), do: capture(fn -> Verify.main(argv) end)

  defp capture(fun) do
    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(self(), {:exit_code, fun.()}) end)
        send(self(), {:stdout, stdout})
      end)

    assert_received {:exit_code, code}
    assert_received {:stdout, stdout}

    {code, stdout <> stderr}
  end

  defp legacy(plaintext), do: "legacy:" <> String.reverse(plaintext)

  defp insert_card(attrs) do
    row = attrs |> Map.new() |> Map.put_new(:merchant_id, @merchant)
    {1, [%{id: id}]} = TestRepo.insert_all("cards", [row], returning: [:id])
    id
  end
end
