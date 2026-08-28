defmodule Mix.Tasks.Encryptor.Ecto.Gen.MigrationTest do
  @moduledoc """
  `mix encryptor.ecto.gen.migration`: what it writes, and what it will not do.

  The generator is the one place in this package where a `CREATE TABLE` gets
  authored, and ADR-0002 decision 9 draws its line between authoring the DDL
  and holding authority over the host's schema. So the assertions here are as
  much about the second as the first: the file lands in the host's tree and
  nothing runs it, the column set is the one the engine's checkpoint reads and
  writes, and a table that already has a migration gets a refusal rather than
  a second one.

  Everything is written into a temporary directory through
  `--migrations-path`, so no test writes into this project's own `priv/`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Encryptor.Ecto.Migrator.Checkpoint
  alias Mix.Tasks.Encryptor.Ecto.Gen.Migration

  setup do
    path = Path.join(System.tmp_dir!(), "ece-5qb-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)

    {:ok, path: path}
  end

  # Sabotage: dropped `prefix` from the generated unique index - the migration
  # still applied, and a host that ran `run/2` over two prefixes had the
  # second one resume at the first's cursor and silently skip every row below
  # it. Nothing at runtime notices; the index is the only thing that can.
  test "writes the checkpoint table the engine actually reads", %{path: path} do
    assert {0, output} = generate(["--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*_create_encryptor_ecto_migration_checkpoints.exs"))
    source = File.read!(file)

    assert output =~ file
    assert source =~ "create table(:#{Checkpoint.default_table()})"
    assert source =~ "add(:plan, :string, null: false)"
    assert source =~ "add(:schema, :string, null: false)"
    assert source =~ "add(:field, :string, null: false)"
    assert source =~ ~s|add(:prefix, :string, null: false, default: "")|
    assert source =~ "add(:last_id, :string, null: false)"
    assert source =~ "add(:counts, :map)"

    assert source =~
             "create(unique_index(:#{Checkpoint.default_table()}, [:plan, :schema, :field, :prefix]))"
  end

  test "the file it writes is valid Elixir and an Ecto migration", %{path: path} do
    assert {0, _output} = generate(["--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*.exs"))
    source = File.read!(file)

    assert {:ok, _ast} = Code.string_to_quoted(source)
    assert source =~ "use Ecto.Migration"
    assert source =~ "def change do"

    assert source =~
             "defmodule EncryptorEcto.Repo.Migrations.CreateEncryptorEctoMigrationCheckpoints do"
  end

  test "it says in the file that the host owns it", %{path: path} do
    assert {0, _output} = generate(["--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*.exs"))
    source = File.read!(file)

    assert source =~ "issues no DDL"
    assert source =~ "mix ecto.migrate"
    assert source =~ "checkpoint_table:"
  end

  # Sabotage: dropped `unwritten/2` so a second run wrote a second file - both
  # migrations ran on the way up, the second `CREATE TABLE` failed, and the
  # host's deploy broke on a table it already had.
  test "refuses to write a second migration for the same table", %{path: path} do
    assert {0, _first} = generate(["--migrations-path", path])
    assert {2, output} = generate(["--migrations-path", path])

    assert output =~ "already creates this table"
    assert length(Path.wildcard(Path.join(path, "*.exs"))) == 1
  end

  test "--table renames the table in the DDL and in the index", %{path: path} do
    assert {0, _output} = generate(["--migrations-path", path, "--table", "ciphertext_cursors"])

    [file] = Path.wildcard(Path.join(path, "*_create_ciphertext_cursors.exs"))
    source = File.read!(file)

    assert source =~ "create table(:ciphertext_cursors)"
    assert source =~ "create(unique_index(:ciphertext_cursors,"
  end

  # Sabotage: dropped the `--table` name check - a name with a closing paren
  # in it was interpolated into the generated source, which is a file this
  # package writes into the host's tree from an argument off the command line.
  test "refuses a table name it would have to quote", %{path: path} do
    assert {2, output} = generate(["--migrations-path", path, "--table", "cards); DROP TABLE"])

    assert output =~ "--table expects an unquoted table name"
    assert Path.wildcard(Path.join(path, "*.exs")) == []
  end

  test "takes no positional arguments, and says which verbs do", %{path: path} do
    assert {2, output} = generate(["MyApp.Plan", "--migrations-path", path])

    assert output =~ "takes no positional arguments"
    assert output =~ "mix encryptor.ecto.migrate"
  end

  test "an unknown flag is a usage error", %{path: path} do
    assert {2, output} = generate(["--migrations-path", path, "--repo", "MyApp.Repo"])
    assert output =~ "--repo"
  end

  defp generate(argv) do
    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(self(), {:exit_code, Migration.main(argv)}) end)
        send(self(), {:stdout, stdout})
      end)

    assert_received {:exit_code, code}
    assert_received {:stdout, stdout}

    {code, stdout <> stderr}
  end
end
