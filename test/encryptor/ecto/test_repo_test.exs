defmodule Encryptor.Ecto.TestRepoTest do
  @moduledoc """
  The repository harness proving itself, before anything is built on it.

  These assertions are about the harness rather than about this package's
  types: that the migration ran, that the encrypted columns really are
  `bytea`, and that arbitrary bytes survive a write and a read unchanged.
  Everything the type tests later claim about a ciphertext round trip rests on
  the last of those, and a column that silently mangled high bytes would make
  every one of those claims meaningless.
  """

  use Encryptor.Ecto.RepoCase, async: true

  alias Ecto.Adapters.SQL

  describe "the migrated schema" do
    # sabotage: TestMigration's :pan column type :binary -> :string, red.
    test "gives both encrypted columns a bytea type" do
      %{rows: rows} =
        SQL.query!(
          TestRepo,
          """
          SELECT column_name, data_type
            FROM information_schema.columns
           WHERE table_name = 'cards'
           ORDER BY column_name
          """,
          []
        )

      assert [
               ["id", "bigint"],
               ["merchant_id", "character varying"],
               ["notes", "bytea"],
               ["pan", "bytea"]
             ] = rows
    end
  end

  describe "a bytea column" do
    # sabotage: TestMigration's add(:pan, :binary) line deleted, red.
    test "returns the bytes it was given, byte for byte" do
      # Deliberately not a printable string: a ciphertext is arbitrary bytes,
      # and a driver or column type that only handles text would pass a test
      # written with a word in it.
      bytes = <<0, 255, 10, 13, 0x80, 0x00, 254>>

      %{rows: [[id]]} =
        SQL.query!(
          TestRepo,
          "INSERT INTO cards (merchant_id, pan) VALUES ($1, $2) RETURNING id",
          ["merchant_7f3", bytes]
        )

      %{rows: [[read_back]]} =
        SQL.query!(TestRepo, "SELECT pan FROM cards WHERE id = $1", [id])

      assert read_back == bytes
    end

    # No sabotage note: this characterizes what a bytea column does with a
    # NULL, not what this package's code does. There is nothing of ours to
    # break that would drive it red - the same reason ece-cuo's :database
    # positive control carries none.
    test "keeps a NULL distinct from empty bytes" do
      %{rows: [[null_id]]} =
        SQL.query!(
          TestRepo,
          "INSERT INTO cards (merchant_id, pan) VALUES ($1, $2) RETURNING id",
          ["merchant_7f3", nil]
        )

      %{rows: [[empty_id]]} =
        SQL.query!(
          TestRepo,
          "INSERT INTO cards (merchant_id, pan) VALUES ($1, $2) RETURNING id",
          ["merchant_7f3", <<>>]
        )

      %{rows: rows} =
        SQL.query!(
          TestRepo,
          "SELECT id, pan FROM cards WHERE id = ANY($1) ORDER BY id",
          [[null_id, empty_id]]
        )

      assert [[^null_id, nil], [^empty_id, <<>>]] = rows
    end
  end
end
