defmodule Encryptor.Ecto.Migrator.CheckpointTest do
  @moduledoc """
  The checkpoint row: its key, its rendered cursor, and the refusal that
  stands where a `CREATE TABLE` would be convenient.

  The prefix component of the key gets a test of its own because ADR-0002
  proposed amendment 6 found the failure it prevents: with one row shared by
  every prefix, the second prefix resumes at the first's cursor and silently
  skips every row below it.
  """

  use Encryptor.Ecto.RepoCase, async: false

  alias Encryptor.Ecto.Migrator.Checkpoint
  alias Encryptor.Ecto.TestRepo
  alias Encryptor.Ecto.TestSchemas

  doctest Encryptor.Ecto.Migrator.Checkpoint, import: true

  @key {:id, :integer}

  describe "render_cursor/2 and parse_cursor/2" do
    # Sabotage: rendered a binary key with `to_string/1` - the stored text was
    # not the bytes, and the parsed cursor paged from somewhere else entirely.
    test "a binary key round-trips through the stored text" do
      cursor = <<0, 1, 254, 255>>
      text = Checkpoint.render_cursor(cursor, {:id, :binary})

      assert Checkpoint.parse_cursor(text, {:id, :binary}) == cursor
    end

    # Sabotage: rendered a UUID key as `inspect/1` - the text was unparseable
    # and every resumed run silently re-scanned from the beginning.
    test "a UUID key round-trips as its string form" do
      cursor = Ecto.UUID.generate()
      text = Checkpoint.render_cursor(cursor, {:id, :binary_id})

      assert Checkpoint.parse_cursor(text, {:id, :binary_id}) == cursor
    end

    # Sabotage: made `parse_cursor/2` raise on unparseable text - a corrupt
    # checkpoint row took the pass down instead of costing it a re-scan, which
    # probe-first makes free.
    test "text that cannot be parsed is nil rather than a raise" do
      assert Checkpoint.parse_cursor("zz", {:id, :binary}) == nil
      assert Checkpoint.parse_cursor("not a uuid", {:id, :binary_id}) == nil
    end
  end

  describe "record/5 and fetch_cursor/4" do
    # Sabotage: dropped `on_conflict` from the upsert - the second batch
    # raised a unique-violation instead of moving the cursor forward.
    test "the second batch moves the cursor rather than colliding" do
      :ok = Checkpoint.record(TestRepo, table(), key(nil), "10", %{"migratable" => 10})
      :ok = Checkpoint.record(TestRepo, table(), key(nil), "20", %{"migratable" => 20})

      assert Checkpoint.fetch_cursor(TestRepo, table(), key(nil), @key) == 20
    end

    # Sabotage: dropped the `prefix` component from the `where` - the second
    # prefix read the first's cursor and skipped every row below it, which is
    # the finding amendment 6 records.
    test "each prefix keeps its own cursor" do
      :ok = Checkpoint.record(TestRepo, table(), key(nil), "10", %{})
      :ok = Checkpoint.record(TestRepo, table(), key("tenant_b"), "3", %{})

      assert Checkpoint.fetch_cursor(TestRepo, table(), key(nil), @key) == 10
      assert Checkpoint.fetch_cursor(TestRepo, table(), key("tenant_b"), @key) == 3
    end

    # Sabotage: made `fetch_cursor/4` raise on no row - the first run of a
    # plan, which by definition has no checkpoint, could not start.
    test "a field with no checkpoint row resumes from nothing" do
      assert Checkpoint.fetch_cursor(TestRepo, table(), key(nil), @key) == nil
    end
  end

  describe "preflight/2" do
    # Sabotage: made `preflight/2` answer `:ok` unconditionally - a missing
    # table was found on the first batch's insert instead of before the first
    # row.
    test "an absent table is a refusal naming the generator" do
      assert {:error, message} = Checkpoint.preflight(TestRepo, "no_such_table")
      assert message =~ "mix encryptor.ecto.gen.migration"
      assert message =~ "issues no DDL"
    end
  end

  describe "preflight/2 on the real table" do
    # Sabotage: made the query select every row rather than one - the check
    # read a whole checkpoint table to answer a question about its existence.
    test "the generated table passes" do
      assert Checkpoint.preflight(TestRepo, table()) == :ok
    end
  end

  defp table, do: Checkpoint.default_table()

  defp key(prefix) do
    %{plan: Some.Plan, schema: TestSchemas.Card, field: :pan, prefix: prefix}
  end
end
