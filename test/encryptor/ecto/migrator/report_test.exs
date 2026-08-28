defmodule Encryptor.Ecto.Migrator.ReportTest do
  @moduledoc """
  The report's counting, its bounded failure list, and the additive shape the
  fifth class (`ece-4mg`) will arrive through.
  """

  use ExUnit.Case, async: true

  alias Encryptor.Ecto.Migrator.Report

  describe "new/1" do
    # Sabotage: made `new/1` start `counts` at `%{}` - a report that had seen
    # no undecryptable row stopped saying `undecryptable 0`, and an operator
    # reading it had to know the class existed to notice it was missing.
    test "starts every class at zero, in the order a report prints them" do
      report = Report.new(:write)

      assert report.mode == :write
      assert Map.keys(report.counts) |> Enum.sort() == Enum.sort(Report.classes())
      assert Enum.all?(Map.values(report.counts), &(&1 == 0))
      assert report.finished_at == nil
    end
  end

  describe "counting" do
    # Sabotage: made `count/2` replace rather than increment - every class
    # reported at most one row.
    test "counts a class and leaves the others alone" do
      report = Report.new(:dry_run) |> Report.count(:null) |> Report.count(:null)

      assert report.counts.null == 2
      assert report.counts.migratable == 0
    end

    # Sabotage: made `count_concurrent/1` count into `:already_target` - a row
    # the application rewrote was reported as one the migrator found already
    # migrated, which are different facts about different moments.
    test "a concurrent row is counted apart from the classes" do
      report = Report.new(:write) |> Report.count_concurrent()

      assert report.concurrent == 1
      assert report.counts.already_target == 0
    end
  end

  describe "failures" do
    # Sabotage: made `record_failure/2` skip the `:undecryptable` count - the
    # classification stopped adding up to the rows visited.
    test "a failure is recorded and also classified" do
      report = Report.new(:write) |> Report.record_failure(failure(1))

      assert report.failure_count == 1
      assert report.counts.undecryptable == 1
      assert [%{id: 1}] = report.failures
      refute Report.ok?(report)
    end

    # Sabotage: dropped the `failure_count < @failure_limit` guard - a pass
    # over a shredded tenant's table held every failure in memory, in the one
    # process that also holds a batch of plaintext.
    test "the list is bounded and the count is not" do
      report =
        Enum.reduce(1..(Report.failure_limit() + 5), Report.new(:write), fn id, report ->
          Report.record_failure(report, failure(id))
        end)

      assert report.failure_count == Report.failure_limit() + 5
      assert length(report.failures) == Report.failure_limit()
      assert List.last(report.failures).id == Report.failure_limit()
    end
  end

  describe "cursors" do
    # Sabotage: dropped the prefix from `put_cursor/5`'s key - two prefixes'
    # cursors collapsed onto one entry, which is the in-memory face of the
    # silent skip ADR-0002 proposed amendment 6 found.
    test "a cursor is keyed by schema, field and prefix" do
      report =
        Report.new(:write)
        |> Report.put_cursor(Some.Schema, :pan, nil, 10)
        |> Report.put_cursor(Some.Schema, :pan, "tenant_b", 4)

      assert report.cursors[{Some.Schema, :pan, nil}] == 10
      assert report.cursors[{Some.Schema, :pan, "tenant_b"}] == 4
    end
  end

  describe "finish/1 and ok?/1" do
    # Sabotage: made `ok?/1` answer on the migratable count - a pass that
    # rewrote nothing because everything was already migrated was reported as
    # a failure.
    test "a pass with no failures is ok however little it did" do
      report = Report.new(:dry_run) |> Report.count(:already_target) |> Report.finish()

      assert Report.ok?(report)
      assert %DateTime{} = report.finished_at
    end
  end

  defp failure(id), do: %{schema: Some.Schema, field: :pan, id: id, reason: :load_failed}
end
