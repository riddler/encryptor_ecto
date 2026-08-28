defmodule Encryptor.Ecto.Migrator.Checkpoint do
  @moduledoc """
  Where a pass records how far it got, and what it refuses to do about the
  table it records into.

  ADR-0002 decision 6: after each batch the migrator records
  `{plan, schema, field, last_id, counts, started_at, updated_at}` in a
  checkpoint table, and `run/2` with `resume: true` starts after the recorded
  cursor. Decision 5 is what makes that merely a performance record: the pass
  probes every row before rewriting it, so losing a checkpoint costs a
  re-scan and never correctness.

  ## The key carries the prefix

  ADR-0002 proposed amendment 6 (status: proposed, `ece-l6t`) adds the prefix
  to the key, and this module is built to that text. Without it, a caller
  looping `run/2` over prefixes - which is exactly what the record tells a
  host with several to do - has every prefix sharing one checkpoint row, so
  the second prefix resumes at the first's cursor and **silently skips every
  row below it**. Probe-first idempotence does not cover that: it makes a
  re-visited row safe, and this is a row never visited.

  A prefix of `nil` - the repo's own default prefix - is stored as the empty
  string rather than as `NULL`, because a `NULL` component defeats the unique
  index in every adapter that treats `NULL`s as distinct, which is the same
  silent-skip failure by a different route.

  ## The table is the host's, and this package will not create it

  ADR-0002 decision 9: no `CREATE TABLE`, at runtime or from a task. The table
  arrives as generated migration source the host reads, commits, and runs with
  its own `mix ecto.migrate` (`mix encryptor.ecto.gen.migration`, `ece-5qb`).
  So `preflight/2` *checks* and refuses, naming the generator; it is the one
  place where creating the table would be convenient, which is exactly why the
  line is drawn here.

  `checkpoint: :none` keeps the alternative available as a documented degraded
  mode: no checkpoint at all, every run a full scan, which decision 5 makes
  correct rather than merely tolerable.

  ## Its shape

  One row per field per prefix, with a unique index over
  `{plan, schema, field, prefix}`:

  | Column | |
  |---|---|
  | `plan`, `schema`, `field` | the plan module, the schema module, and the field, as text |
  | `prefix` | the schema prefix visited; `""` for the repo's default |
  | `last_id` | the primary key of the last row of the last committed batch, **rendered as text** |
  | `counts` | the classification counts so far, as a map |
  | `started_at`, `updated_at` | when the pass began and when this row was last written |

  `last_id` is text because ADR-0002 proposed amendment 4 admits both integer
  and binary primary keys and one checkpoint table serves both. Rendering and
  parsing are this module's (`render_cursor/2`, `parse_cursor/2`), and the
  key's type travels with it so the value is parsed back at exactly the type
  it was compared at.

  ## A dry run never writes one

  `record/5` is called only in `:write` mode. A dry run that recorded a cursor
  would let a later write-mode run resume past rows it never wrote - a silent
  skip produced by the rehearsal, which is the one thing a rehearsal must not
  do. Reading a checkpoint in a dry run is fine and is what makes the
  rehearsal resemble the run.
  """

  import Ecto.Query, only: [from: 2]

  alias Encryptor.Ecto.Migrator.Keyset

  @default_table "encryptor_ecto_migration_checkpoints"

  @typedoc "Which row of the checkpoint table a field's pass owns."
  @type key :: %{
          plan: module(),
          schema: module(),
          field: atom(),
          prefix: String.t() | nil
        }

  @doc """
  The table name a host gets unless it names another.

      iex> Encryptor.Ecto.Migrator.Checkpoint.default_table()
      "encryptor_ecto_migration_checkpoints"
  """
  @spec default_table() :: String.t()
  def default_table, do: @default_table

  @doc """
  Confirms the checkpoint table exists, and refuses when it does not.

  Returns `:ok`, or `{:error, message}` naming the generator. The refusal is a
  message rather than a `CREATE TABLE` for the reason ADR-0002 decision 9
  gives; the caller raises it, once, before the first batch of the first
  field.
  """
  @spec preflight(module(), String.t()) :: :ok | {:error, String.t()}
  def preflight(repo, table) do
    _rows = repo.all(from(c in table, select: 1, limit: 1))
    :ok
  rescue
    _exception -> {:error, missing_table_message(table)}
  end

  @doc """
  The cursor a previous pass over this field and prefix recorded, if any.

  A row whose `last_id` cannot be parsed back at the key's type is treated as
  absent: the pass re-scans, which decision 5 makes correct, rather than
  paging from a cursor nobody can vouch for.
  """
  @spec fetch_cursor(module(), String.t(), key(), Keyset.key()) :: term() | nil
  def fetch_cursor(repo, table, key, keyset_key) do
    query =
      from(c in table,
        where:
          c.plan == ^module_text(key.plan) and c.schema == ^module_text(key.schema) and
            c.field == ^Atom.to_string(key.field) and c.prefix == ^prefix_text(key.prefix),
        select: c.last_id,
        limit: 1
      )

    case repo.all(query) do
      [last_id] when is_binary(last_id) -> parse_cursor(last_id, keyset_key)
      _none -> nil
    end
  end

  @doc """
  Records one batch's cursor and counts, in the transaction that wrote it.

  Written by the same transaction as the batch it describes, so the two are
  consistent by construction - a cursor written beside a transaction rather
  than inside it disagrees with the rows whenever a crash lands between them.
  """
  @spec record(module(), String.t(), key(), String.t(), map()) :: :ok
  def record(repo, table, key, last_id, counts) when is_binary(last_id) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    row = [
      plan: module_text(key.plan),
      schema: module_text(key.schema),
      field: Atom.to_string(key.field),
      prefix: prefix_text(key.prefix),
      last_id: last_id,
      counts: counts,
      started_at: now,
      updated_at: now
    ]

    {_count, _rows} =
      repo.insert_all(table, [row],
        on_conflict: [set: [last_id: last_id, counts: counts, updated_at: now]],
        conflict_target: [:plan, :schema, :field, :prefix]
      )

    :ok
  end

  @doc """
  Renders a primary key as the text the checkpoint row stores.

      iex> alias Encryptor.Ecto.Migrator.Checkpoint
      iex> Checkpoint.render_cursor(42, {:id, :integer})
      "42"
      iex> Checkpoint.render_cursor(<<1, 2>>, {:id, :binary})
      "0102"
  """
  @spec render_cursor(term(), Keyset.key()) :: String.t()
  def render_cursor(cursor, {_column, :integer}), do: Integer.to_string(cursor)
  def render_cursor(cursor, {_column, :binary}), do: Base.encode16(cursor)

  def render_cursor(cursor, {_column, :binary_id}) do
    case Ecto.UUID.cast(cursor) do
      {:ok, uuid} -> uuid
      :error -> Base.encode16(cursor)
    end
  end

  @doc """
  Parses a stored `last_id` back into a cursor, or `nil` when it cannot.

      iex> alias Encryptor.Ecto.Migrator.Checkpoint
      iex> Checkpoint.parse_cursor("42", {:id, :integer})
      42
      iex> Checkpoint.parse_cursor("not a number", {:id, :integer})
      nil
  """
  @spec parse_cursor(String.t(), Keyset.key()) :: term() | nil
  def parse_cursor(text, {_column, :integer}) do
    case Integer.parse(text) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  def parse_cursor(text, {_column, :binary}) do
    case Base.decode16(text) do
      {:ok, binary} -> binary
      :error -> nil
    end
  end

  def parse_cursor(text, {_column, :binary_id}) do
    case Ecto.UUID.cast(text) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  @doc """
  The empty string a default prefix is stored as.

      iex> Encryptor.Ecto.Migrator.Checkpoint.prefix_text(nil)
      ""
      iex> Encryptor.Ecto.Migrator.Checkpoint.prefix_text("tenant_a")
      "tenant_a"
  """
  @spec prefix_text(String.t() | nil) :: String.t()
  def prefix_text(nil), do: ""
  def prefix_text(prefix) when is_binary(prefix), do: prefix

  @spec module_text(module()) :: String.t()
  defp module_text(module), do: inspect(module)

  defp missing_table_message(table) do
    "the checkpoint table #{inspect(table)} could not be read in this repo, " <>
      "and this package issues no DDL (ADR-0002 decision 9), so a missing " <>
      "table is refused rather than created. Generate the migration with " <>
      "`mix encryptor.ecto.gen.migration`, review it, and run it with your " <>
      "own `mix ecto.migrate`. To run with no checkpoint at all, " <>
      "pass `checkpoint: :none`: every run becomes a full scan, which " <>
      "probe-first idempotence (decision 5) makes correct rather than merely " <>
      "tolerable."
  end
end
