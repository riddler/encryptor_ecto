defmodule Mix.Tasks.Encryptor.Ecto.Gen.SuspensionStoreMigrationTest do
  @moduledoc """
  `mix encryptor.ecto.gen.suspension_store_migration`: what it writes, and
  that the suite's own migration is the same table.

  The `:database` tests run against
  `Encryptor.Ecto.TestMigrationSuspensions`, a hand-written stand-in for this
  generator's output, so the two are compared line by line. The refusals it
  shares with the key-store generators come from `CLI.gen/2` and are pinned
  there; the one repeated here is the refusal to write a second file.

  Everything is written into a temporary directory through
  `--migrations-path`, so no test writes into this project's own `priv/`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Encryptor.Ecto.SuspensionStore
  alias Mix.Tasks.Encryptor.Ecto.Gen.SuspensionStoreMigration

  setup do
    path = Path.join(System.tmp_dir!(), "ece-dct-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)

    {:ok, path: path}
  end

  # Sabotage: dropped the `{vault, selector}` unique index from the
  # generated source, which `suspend/2`'s `ON CONFLICT` names. The index
  # assertion went red.
  test "writes the table the store reads", %{path: path} do
    assert {0, output} = generate(["--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*_create_encryptor_suspensions.exs"))
    source = File.read!(file)
    table = SuspensionStore.default_table()

    assert output =~ file
    assert source =~ "create table(:#{table})"
    assert source =~ "add(:vault, :string, null: false)"
    assert source =~ "add(:selector, :string, null: false)"
    assert source =~ "add(:inserted_at, :utc_datetime, null: false)"
    assert source =~ "create(unique_index(:#{table}, [:vault, :selector]))"
  end

  # Sabotage: made `selector` nullable in the generated source only. Every
  # `:database` test stayed green - they run the hand-written migration -
  # and this comparison went red.
  test "the generated source and the suite's own migration agree", %{path: path} do
    assert {0, _output} = generate(["--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*.exs"))
    generated = ddl_lines(File.read!(file))
    fixture = ddl_lines(File.read!("test/support/test_migration_suspensions.ex"))

    assert generated == fixture
  end

  # Sabotage: reworded the generated comment's "issues no DDL". The
  # ownership assertion went red.
  test "the file it writes is valid Elixir, an Ecto migration, and the host's", %{path: path} do
    assert {0, _output} = generate(["--table", "vault_suspensions", "--migrations-path", path])

    [file] = Path.wildcard(Path.join(path, "*_create_vault_suspensions.exs"))
    source = File.read!(file)

    assert {:ok, _ast} = Code.string_to_quoted(source)
    assert source =~ "use Ecto.Migration"
    assert source =~ "defmodule EncryptorEcto.Repo.Migrations.CreateVaultSuspensions do"
    assert source =~ "create table(:vault_suspensions)"
    assert source =~ "issues no DDL"
    assert source =~ "mix ecto.migrate"
  end

  # Sabotage: passed `already_written: :alter`. The refusal read "already
  # adds these columns" and the message assertion went red.
  test "it never writes a second migration for a table it already wrote", %{path: path} do
    assert {0, _output} = generate(["--migrations-path", path])
    assert {2, output} = generate(["--migrations-path", path])

    assert output =~ "already creates this table"
    assert length(Path.wildcard(Path.join(path, "*.exs"))) == 1
  end

  defp generate(argv) do
    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn -> send(self(), {:exit_code, SuspensionStoreMigration.main(argv)}) end)

        send(self(), {:stdout, stdout})
      end)

    assert_received {:exit_code, code}
    assert_received {:stdout, stdout}

    {code, stdout <> stderr}
  end

  defp ddl_lines(source) do
    source
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 =~ ~r/^(create |add\()/))
  end
end
