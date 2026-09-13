defmodule Mix.Tasks.Encryptor.Ecto.Gen.KeyStoreShapeMigration do
  @shortdoc "Writes the additive migration that adds wrapping_shape and key_id"

  @moduledoc """
  Generates the migration that brings an existing wrapped-key table up to
  ADR-0005's row shape.

      mix encryptor.ecto.gen.key_store_shape_migration [--table NAME] [--migrations-path PATH]

  A table created under 0.3.0 holds the six fields
  `Encryptor.Envelope.WrappedKey` fixes and nothing else.
  `Encryptor.Ecto.KeyStore` now also selects `wrapping_shape` and `key_id`
  (ADR-0005 decisions 1 and 2), so it names two columns that table does not
  have. Run this migration before deploying the new version, not after: until
  it runs, every read of that table raises the `Postgrex.Error` naming the
  column that is missing, which is a permanent condition and reports itself as
  one (ADR-0005 decision 7, and its open question 3, now answered - the bare
  rescue that used to report this as a retryable
  `{:key_unavailable, selector}` is gone).

  ## Why this is a second task

  `mix encryptor.ecto.gen.key_store_migration` writes `CREATE TABLE` and
  refuses, with exit 2, where a migration for the table already exists - a
  repeated `CREATE TABLE` fails on the way up. That refusal is right and it is
  also why that task cannot serve an adopter: an existing table needs an
  `ALTER`, not a second `CREATE`. Fresh adopters need only the first task,
  whose DDL already carries both columns.

  ## This task issues no DDL

  Like its sibling it writes one file, opens no database connection, and runs
  nothing (ADR-0002 decision 9). The file is yours the moment it lands: review
  it in a diff, commit it, and run it with your own `mix ecto.migrate` on your
  own deploy schedule. The module name is generated from this project's
  application name and will need renaming if your repo lives in another
  namespace.

  ## Flags

  | Flag | | |
  |---|---|---|
  | `--table NAME` | `encryptor_wrapped_keys` | The table to alter. A host that renamed it passes the same name it passes as `table:` in its `Encryptor.Ecto.KeyStore` provider options |
  | `--migrations-path PATH` | `priv/repo/migrations` | Where to write the file |

  ## Exit codes

  | | |
  |---|---|
  | `0` | The file was written; its path is printed |
  | `2` | Usage error, or an additive migration for this table already exists in that directory - the generator never overwrites one and never writes a second |

  ## The shape it writes

  Two `alter` blocks, in that order, and no index.

  The first adds `wrapping_shape` with `default: "engine_message"`, which is
  what makes `null: false` possible on a populated table in one statement. The
  default is correct rather than convenient: the shipped 0.3.0 read path calls
  `Encryptor.Envelope.unwrap/2` for every row with no branch at all, so a row
  that is not an engine message is a row that code could never have read.
  There are none.

  The second sets that default to `NULL`, in the same migration. A permanent
  default would mean a host inserting a GCP-wrapped row and forgetting the
  column gets a row that claims to be an engine message and fails later, during
  someone else's rotation. `from:` on the `modify` is what makes the whole
  thing reversible, so `mix ecto.rollback` is available on the way back.

  No index: neither column is ever a lookup key - the lookup key is
  `tenant_ref` - and an index on a two-valued column over a table with one row
  per tenant per version buys nothing.
  """

  use Mix.Task

  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.Migrator.CLI

  @default_path "priv/repo/migrations"
  @switches [table: :string, migrations_path: :string]

  @impl Mix.Task
  def run(argv) do
    argv |> main() |> CLI.halt()
  end

  @doc false
  @spec main([String.t()]) :: 0 | 2
  def main(argv) do
    with {:ok, table, path} <- parse(argv),
         :ok <- unwritten(table, path) do
      generate(table, path)
    else
      {:error, message} -> CLI.usage_error(message)
    end
  end

  @doc false
  @spec source(String.t(), module()) :: String.t()
  def source(table, module) do
    """
    defmodule #{inspect(module)} do
      # Adds ADR-0005's two columns to an existing wrapped-key table, generated
      # by `mix encryptor.ecto.gen.key_store_shape_migration`.
      #
      # `encryptor_ecto` issues no DDL of its own (ADR-0002 decision 9): this
      # file is the host's now. Review it, commit it, and run it with your own
      # `mix ecto.migrate` - before you deploy the version that reads the new
      # columns, not after. Rename the module above if your repo lives in
      # another namespace.
      #
      # `wrapping_shape` says which kind of wrapping `wrapped` holds, and every
      # row that exists today is an engine message: the 0.3.0 read path
      # unwrapped every row under the root vault with no branch, so a row of any
      # other kind is one it could never have read. That is why the backfill
      # default is correct and not a guess.
      #
      # The second `alter` takes the default away again. A permanent default
      # would let a host insert a GCP-wrapped row, forget the column, and get a
      # row claiming to be an engine message - a write-time mistake that reports
      # as a read-time mystery during someone else's rotation. The `from:`
      # clause is what keeps the whole change reversible.
      @moduledoc false

      use Ecto.Migration

      def change do
        alter table(:#{table}) do
          add(:wrapping_shape, :string, null: false, default: "engine_message")
          add(:key_id, :string)
        end

        alter table(:#{table}) do
          modify(:wrapping_shape, :string,
            null: false,
            default: nil,
            from: {:string, null: false, default: "engine_message"}
          )
        end
      end
    end
    """
  end

  @doc false
  @spec migration_module(String.t()) :: module()
  def migration_module(table) do
    app =
      Mix.Project.config()
      |> Keyword.fetch!(:app)
      |> Atom.to_string()
      |> Macro.camelize()

    Module.concat([app, "Repo", "Migrations", Macro.camelize("add_wrapping_shape_to_" <> table)])
  end

  @spec parse([String.t()]) :: {:ok, String.t(), String.t()} | {:error, String.t()}
  defp parse(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {parsed, [], []} -> table(parsed)
      {_parsed, [_ | _] = args, []} -> {:error, positional_message(args)}
      {_parsed, _args, invalid} -> {:error, invalid_message(invalid)}
    end
  end

  @spec table(keyword()) :: {:ok, String.t(), String.t()} | {:error, String.t()}
  defp table(parsed) do
    table = Keyword.get(parsed, :table, KeyStore.default_table())
    path = Keyword.get(parsed, :migrations_path, @default_path)

    if table =~ ~r/^[a-z_][a-z0-9_]*$/ do
      {:ok, table, path}
    else
      {:error,
       "--table expects an unquoted table name - lowercase letters, digits and " <>
         "underscores - and cannot use #{inspect(table)}"}
    end
  end

  @spec positional_message([String.t()]) :: String.t()
  defp positional_message(args) do
    "takes no positional arguments and was given #{Enum.join(args, " ")}. This verb " <>
      "writes a file and reads no plan."
  end

  @spec invalid_message([{String.t(), term()}]) :: String.t()
  defp invalid_message(invalid) do
    Enum.map_join(invalid, "\n", fn {flag, _value} ->
      "#{flag} is not a flag of this task, or was given a value of the wrong type."
    end)
  end

  @spec unwritten(String.t(), String.t()) :: :ok | {:error, String.t()}
  defp unwritten(table, path) do
    case Path.wildcard(Path.join(path, "*_add_wrapping_shape_to_#{table}.exs")) do
      [] -> :ok
      [existing | _rest] -> {:error, already_written_message(existing)}
    end
  end

  @spec already_written_message(String.t()) :: String.t()
  defp already_written_message(existing) do
    "#{existing} already adds these columns to this table. The generator never " <>
      "overwrites a migration and never writes a second one for the same table: " <>
      "a repeated `ADD COLUMN` fails on the way up, and the one you have is the " <>
      "one your database was altered by."
  end

  @spec generate(String.t(), String.t()) :: 0
  defp generate(table, path) do
    file = Path.join(path, "#{timestamp()}_add_wrapping_shape_to_#{table}.exs")

    File.mkdir_p!(path)
    File.write!(file, source(table, migration_module(table)))
    Mix.shell().info("* creating #{file}")

    0
  end

  @spec timestamp() :: String.t()
  defp timestamp do
    now = DateTime.utc_now()

    [now.year, now.month, now.day, now.hour, now.minute, now.second]
    |> Enum.map_join(&pad/1)
  end

  @spec pad(integer()) :: String.t()
  defp pad(number) when number < 10, do: "0#{number}"
  defp pad(number), do: Integer.to_string(number)
end
