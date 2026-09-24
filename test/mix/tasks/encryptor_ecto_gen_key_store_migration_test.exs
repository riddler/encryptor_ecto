defmodule Mix.Tasks.Encryptor.Ecto.Gen.KeyStoreMigrationTest do
  @moduledoc """
  `mix encryptor.ecto.gen.key_store_migration`: what it writes, and what it
  will not do.

  ADR-0002 decision 9 draws its line between authoring the DDL and holding
  authority over the host's schema, so the assertions here are as much about
  the second as the first: the file lands in the host's tree and nothing runs
  it, the column set is the six fields the provider reads, and a table that
  already has a migration gets a refusal rather than a second one.

  The last test is the one that keeps the suite honest. The `:database` tests
  run against `Encryptor.Ecto.TestMigrationWrappedKeys`, which is a hand-written
  stand-in for this generator's output; if the two drift, the provider is
  proven against a table no host would ever have. So the generated source is
  compared against that migration line by line.

  Everything is written into a temporary directory through
  `--migrations-path`, so no test writes into this project's own `priv/`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Encryptor.Ecto.KeyStore
  alias Mix.Tasks.Encryptor.Ecto.Gen.KeyStoreMigration

  setup do
    path = Path.join(System.tmp_dir!(), "ece-e3d-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)

    {:ok, path: path}
  end

  # Sabotage: dropped the `{namespace, name}` unique index from the generated
  # source. Two rows could then carry one name with different material, and
  # `RawAes.unwrap_key/3` matches on the name - so the messages written under
  # the first row became undecryptable the moment the second was inserted,
  # silently, with nothing at runtime able to notice.
  test "writes the table the provider actually reads", %{path: path} do
    assert {0, output} = generate(["--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*_create_encryptor_wrapped_keys.exs"))
    source = File.read!(file)
    table = KeyStore.default_table()

    assert output =~ file
    assert source =~ "create table(:#{table})"
    assert source =~ "add(:tenant_ref, :string, null: false)"
    assert source =~ "add(:version, :integer, null: false)"
    assert source =~ "add(:namespace, :string, null: false)"
    assert source =~ "add(:name, :string, null: false)"
    assert source =~ "add(:bits, :integer, null: false)"
    assert source =~ "add(:wrapped, :binary, null: false)"
    assert source =~ "add(:wrapping_shape, :string, null: false)"
    assert source =~ "add(:key_id, :string)"
    assert source =~ "create(unique_index(:#{table}, [:tenant_ref, :version]))"
    assert source =~ "create(unique_index(:#{table}, [:namespace, :name]))"
  end

  # Sabotage: changed `:version` to `:string` in the generated source only.
  # Every `:database` test stayed green - they run the hand-written migration -
  # and a host following the generator got a candidate list ordered
  # lexically, so version 10 sorted below version 9 and writes went under a
  # superseded key.
  test "the generated source and the suite's own migration agree", %{path: path} do
    assert {0, _output} = generate(["--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*.exs"))
    generated = ddl_lines(File.read!(file))
    fixture = ddl_lines(File.read!("test/support/test_migration_wrapped_keys.ex"))

    assert generated == fixture
  end

  # Sabotage: gave `wrapping_shape` `default: "engine_message"` in the fresh
  # table's DDL. A new adopter's forgotten column then became a row claiming to
  # be an engine message, which is precisely what ADR-0005 decision 4 refuses on
  # the write side - the default belongs to the additive migration and nowhere
  # else, because only there is there history to backfill.
  test "the fresh table's wrapping_shape carries no default", %{path: path} do
    assert {0, _output} = generate(["--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*.exs"))

    refute File.read!(file) =~ "default:"
  end

  test "the file it writes is valid Elixir and an Ecto migration", %{path: path} do
    assert {0, _output} = generate(["--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*.exs"))
    source = File.read!(file)

    assert {:ok, _ast} = Code.string_to_quoted(source)
    assert source =~ "use Ecto.Migration"
    assert source =~ "def change do"
    assert source =~ "defmodule EncryptorEcto.Repo.Migrations.CreateEncryptorWrappedKeys do"
  end

  test "it says in the file that the host owns it", %{path: path} do
    assert {0, _output} = generate(["--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*.exs"))
    source = File.read!(file)

    assert source =~ "issues no DDL"
    assert source =~ "mix ecto.migrate"
    assert source =~ "table:"
  end

  test "a renamed table is carried into the file name, module and DDL", %{path: path} do
    assert {0, _output} = generate(["--table", "scope_keys", "--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*_create_scope_keys.exs"))
    source = File.read!(file)

    assert source =~ "create table(:scope_keys)"
    assert source =~ "defmodule EncryptorEcto.Repo.Migrations.CreateScopeKeys do"
  end

  # Sabotage: dropped `unwritten/2` so a second run wrote a second file. Both
  # migrations ran on the way up and the second `CREATE TABLE` failed, in the
  # host's deploy rather than here.
  test "it never writes a second migration for a table it already wrote", %{path: path} do
    assert {0, _output} = generate(["--migrations-path", path])
    assert {2, output} = generate(["--migrations-path", path])

    assert output =~ "already creates this table"
    assert length(Path.wildcard(Path.join(path, "*.exs"))) == 1
  end

  test "it refuses a table name that is not an unquoted identifier", %{path: path} do
    assert {2, output} = generate(["--table", "scope keys", "--migrations-path", path])

    assert output =~ "--table expects an unquoted table name"
    assert Path.wildcard(Path.join(path, "*.exs")) == []
  end

  test "it refuses positional arguments and unknown flags", %{path: path} do
    assert {2, positional} = generate(["some_plan", "--migrations-path", path])
    assert positional =~ "takes no positional arguments"

    assert {2, unknown} = generate(["--nope", "--migrations-path", path])
    assert unknown =~ "is not a flag of this task"
  end

  defp generate(argv) do
    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(self(), {:exit_code, KeyStoreMigration.main(argv)}) end)
        send(self(), {:stdout, stdout})
      end)

    assert_received {:exit_code, code}
    assert_received {:stdout, stdout}

    {code, stdout <> stderr}
  end

  # The `create table` / `add` / `create(...index` lines, normalized, so the
  # comparison is about the DDL and not about the prose either file wraps it in.
  defp ddl_lines(source) do
    source
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 =~ ~r/^(create |add\()/))
  end
end
