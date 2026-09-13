defmodule Mix.Tasks.Encryptor.Ecto.Gen.KeyStoreShapeMigrationTest do
  @moduledoc """
  `mix encryptor.ecto.gen.key_store_shape_migration`: the additive half of
  ADR-0005 decision 6.

  The record fixes this migration's shape rather than leaving it to the task,
  so most of what is asserted here is the record read back out of the generated
  file: two `alter` blocks in that order, a backfill default on the first that
  is gone by the end of the second, a `from:` clause that makes the whole thing
  reversible, and no index.

  The last test is the one that keeps the `:database` suite honest, exactly as
  its sibling's does: the `:database` tests upgrade a 0.3.0 table through
  `Encryptor.Ecto.TestMigrationWrappedKeysShape`, and if that drifts from what
  the generator writes they are proving a migration no host would ever have run.

  Everything is written into a temporary directory through
  `--migrations-path`, so no test writes into this project's own `priv/`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Encryptor.Ecto.KeyStore
  alias Mix.Tasks.Encryptor.Ecto.Gen.KeyStoreShapeMigration

  @fixture_table "encryptor_wrapped_keys_03"

  setup do
    path = Path.join(System.tmp_dir!(), "ece-9wp-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)

    {:ok, path: path}
  end

  # Sabotage: dropped the second `alter` block. The backfill default survived
  # the migration, so a host inserting a GCP-wrapped row and forgetting the
  # column got a row that claimed to be an engine message - a write-time
  # mistake that reports, much later, as somebody else's unwrap failure.
  test "writes both columns, backfills, and takes the default away again", %{path: path} do
    assert {0, output} = generate(["--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*_add_wrapping_shape_to_encryptor_wrapped_keys.exs"))
    source = File.read!(file)
    table = KeyStore.default_table()

    assert output =~ file
    assert source =~ "alter table(:#{table}) do"
    assert source =~ ~s|add(:wrapping_shape, :string, null: false, default: "engine_message")|
    assert source =~ "add(:key_id, :string)"
    assert source =~ "modify(:wrapping_shape, :string,"
    assert source =~ "default: nil,"
    assert source =~ ~s|from: {:string, null: false, default: "engine_message"}|
  end

  # Sabotage: dropped the `from:` clause. The migration still ran up, so every
  # up-only test stayed green, and `mix ecto.rollback` raised in the host's
  # deploy instead - the one moment a host most wants the way back.
  test "it is reversible and adds no index", %{path: path} do
    assert {0, _output} = generate(["--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*.exs"))
    source = File.read!(file)

    assert source =~ "from: {"
    refute source =~ "index"
  end

  test "the file it writes is valid Elixir and an Ecto migration", %{path: path} do
    assert {0, _output} = generate(["--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*.exs"))
    source = File.read!(file)

    assert {:ok, _ast} = Code.string_to_quoted(source)
    assert source =~ "use Ecto.Migration"
    assert source =~ "def change do"

    assert source =~
             "defmodule EncryptorEcto.Repo.Migrations.AddWrappingShapeToEncryptorWrappedKeys do"
  end

  test "it says in the file that the host owns it, and when to run it", %{path: path} do
    assert {0, _output} = generate(["--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*.exs"))
    source = File.read!(file)

    assert source =~ "issues no DDL"
    assert source =~ "mix ecto.migrate"
    assert source =~ "before you deploy"
  end

  test "a renamed table is carried into the file name, module and DDL", %{path: path} do
    assert {0, _output} = generate(["--table", "tenant_keys", "--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*_add_wrapping_shape_to_tenant_keys.exs"))
    source = File.read!(file)

    assert source =~ "alter table(:tenant_keys) do"
    assert source =~ "defmodule EncryptorEcto.Repo.Migrations.AddWrappingShapeToTenantKeys do"
  end

  # Sabotage: dropped `unwritten/2` so a second run wrote a second file. Both
  # migrations ran on the way up and the second `ADD COLUMN` failed, in the
  # host's deploy rather than here.
  test "it never writes a second migration for a table it already altered", %{path: path} do
    assert {0, _output} = generate(["--migrations-path", path])
    assert {2, output} = generate(["--migrations-path", path])

    assert output =~ "already adds these columns"
    assert length(Path.wildcard(Path.join(path, "*.exs"))) == 1
  end

  test "it refuses a table name that is not an unquoted identifier", %{path: path} do
    assert {2, output} = generate(["--table", "tenant keys", "--migrations-path", path])

    assert output =~ "--table expects an unquoted table name"
    assert Path.wildcard(Path.join(path, "*.exs")) == []
  end

  test "it refuses positional arguments and unknown flags", %{path: path} do
    assert {2, positional} = generate(["some_plan", "--migrations-path", path])
    assert positional =~ "takes no positional arguments"

    assert {2, unknown} = generate(["--nope", "--migrations-path", path])
    assert unknown =~ "is not a flag of this task"
  end

  # Sabotage: changed the backfill default in the generated source only. Every
  # `:database` test stayed green - they run the hand-written migration - while
  # a host following the generator backfilled its whole table with a shape
  # nothing recognizes, and read every pre-existing row as
  # `{:unknown_wrapping_shape, _}` after the deploy.
  test "the generated source and the suite's own upgrade migration agree", %{path: path} do
    assert {0, _output} = generate(["--table", @fixture_table, "--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*.exs"))
    generated = ddl_lines(File.read!(file))
    fixture = ddl_lines(File.read!("test/support/test_migration_wrapped_keys_shape.ex"))

    assert generated == fixture
  end

  defp generate(argv) do
    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn -> send(self(), {:exit_code, KeyStoreShapeMigration.main(argv)}) end)

        send(self(), {:stdout, stdout})
      end)

    assert_received {:exit_code, code}
    assert_received {:stdout, stdout}

    {code, stdout <> stderr}
  end

  # Every line of the `change/0` body that carries DDL, normalized, so the
  # comparison is about the migration and not about the prose either file wraps
  # it in. The `modify/3` call is wrapped across four lines in both, and all
  # four are here: the `null:`, the `default:` and the `from:` are the decision.
  defp ddl_lines(source) do
    source
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 =~ ~r/^(alter |add\(|modify\(|null:|default:|from:)/))
  end
end
