defmodule Encryptor.Ecto.Migrator.Report do
  @moduledoc """
  What a pass did: one classification count per class, per-field cursors, and
  the failures it found.

  ADR-0002 decision 7 fixes the classification and decision 11 fixes what
  happens to a row that fits none of it. A report is returned on **both** arms
  of `Encryptor.Ecto.Migrator.run/2`, so a run that halted still says
  everything it did before halting - an operator reading a failed six-hour
  pass needs the counts more than the caller needs an empty error.

  ## The classification

  | Class | Meaning |
  |---|---|
  | `:null` | The column is `NULL`; nothing to do |
  | `:already_target` | The probe succeeded; the row is in the target state |
  | `:migratable` | The probe failed and the `from` load succeeded |
  | `:undecryptable` | Neither side loads; it needs an operator decision |

  `concurrent` is counted separately rather than as a class: a row the
  application rewrote between the migrator's read and its write was already
  counted once, when it was read (ADR-0002 decision 4).

  ## Adding a class is additive, deliberately

  The classes live in one list (`classes/0`), every counter is initialised
  from it, and nothing in this module or in the engine pattern-matches on the
  full set. ADR-0002 proposed amendment 2 adds a fifth class,
  `:migratable_unverified`, for a field whose legacy cipher does not
  authenticate; `ece-4mg` implements it, and doing so is meant to be an entry
  in that list plus the code that decides when to use it. This module is
  arranged so that it is.

  ## Nothing here carries a value

  A failure records the schema, the field, the primary key and the reason -
  never the plaintext, never the ciphertext bytes, never key material
  (ADR-0002 decision 11, ADR-0001 decision 6). The reasons the engine records
  are the ones `Encryptor.Ecto.Migrator.Source` composes, which are already
  reduced to module names and atoms for the same reason.

  The failure list is bounded at 100 entries while `failure_count` keeps
  counting: a pass over a table whose key was destroyed produces one failure
  per row, and a report that tried to hold all of them would exhaust the
  memory of the process holding every plaintext in the database.
  """

  alias Encryptor.Ecto.Migrator

  @failure_limit 100

  @typedoc "How a row was classified (ADR-0002 decision 7)."
  @type class :: :null | :already_target | :migratable | :undecryptable

  @typedoc """
  One row that could not be read from either side.

  `:id` is the row's primary key, which is not a secret and is the only way an
  operator finds the row again.
  """
  @type failure :: %{schema: module(), field: atom(), id: term(), reason: term()}

  @typedoc """
  What a cursor belongs to: a schema, a field, and the prefix that was visited.

  The prefix component is ADR-0002 proposed amendment 6: without it, a caller
  looping `run/2` over prefixes has the second prefix resume at the first's
  cursor and silently skip every row below it.
  """
  @type cursor_key :: {module(), atom(), String.t() | nil}

  @type t :: %__MODULE__{
          mode: Migrator.mode(),
          counts: %{class() => non_neg_integer()},
          concurrent: non_neg_integer(),
          failures: [failure()],
          failure_count: non_neg_integer(),
          cursors: %{cursor_key() => term()},
          started_at: DateTime.t(),
          finished_at: DateTime.t() | nil
        }

  @enforce_keys [:mode, :counts, :started_at]
  defstruct [
    :mode,
    :counts,
    :started_at,
    :finished_at,
    concurrent: 0,
    failures: [],
    failure_count: 0,
    cursors: %{}
  ]

  @doc """
  Every class a row can be given, in the order a report prints them.

      iex> Encryptor.Ecto.Migrator.Report.classes()
      [:null, :already_target, :migratable, :undecryptable]
  """
  @spec classes() :: [class()]
  def classes, do: [:null, :already_target, :migratable, :undecryptable]

  @doc """
  How many failures a report holds before it stops holding them.

      iex> Encryptor.Ecto.Migrator.Report.failure_limit()
      100
  """
  @spec failure_limit() :: pos_integer()
  def failure_limit, do: @failure_limit

  @doc """
  A report for a pass that is about to start, with every class at zero.

  Zeroed rather than empty so that a report always names every class: an
  operator reading `undecryptable 0` has been told something, and one reading
  a map with no `:undecryptable` key has to know the class exists to notice it
  is missing.
  """
  @spec new(Migrator.mode()) :: t()
  def new(mode) do
    %__MODULE__{
      mode: mode,
      counts: Map.new(classes(), &{&1, 0}),
      started_at: DateTime.utc_now()
    }
  end

  @doc "Counts one row into a class."
  @spec count(t(), class()) :: t()
  def count(%__MODULE__{} = report, class) do
    %{report | counts: Map.update(report.counts, class, 1, &(&1 + 1))}
  end

  @doc """
  Counts one row the application rewrote while the migrator held it.

  Not a class: the row was already counted when it was read (ADR-0002
  decision 4).
  """
  @spec count_concurrent(t()) :: t()
  def count_concurrent(%__MODULE__{} = report),
    do: %{report | concurrent: report.concurrent + 1}

  @doc """
  Records one failure, keeping the list bounded and the count exact.

  The row is *also* counted `:undecryptable`, because the classification is
  about rows and the failure list is about what an operator has to go and look
  at.
  """
  @spec record_failure(t(), failure()) :: t()
  def record_failure(%__MODULE__{} = report, failure) do
    failures =
      if report.failure_count < @failure_limit do
        report.failures ++ [failure]
      else
        report.failures
      end

    %{report | failures: failures, failure_count: report.failure_count + 1}
    |> count(:undecryptable)
  end

  @doc """
  Records how far one field's pass got, in the prefix it was visiting.
  """
  @spec put_cursor(t(), module(), atom(), String.t() | nil, term()) :: t()
  def put_cursor(%__MODULE__{} = report, schema, field, prefix, cursor) do
    %{report | cursors: Map.put(report.cursors, {schema, field, prefix}, cursor)}
  end

  @doc "Stamps the finish time. Idempotent in effect; the last stamp wins."
  @spec finish(t()) :: t()
  def finish(%__MODULE__{} = report), do: %{report | finished_at: DateTime.utc_now()}

  @doc """
  Whether the pass found nothing an operator has to decide about.

  This is the `{:ok, report}` / `{:error, report}` arm and the task family's
  exit code, and it is deliberately about failures rather than about work
  done: a pass that rewrote nothing because everything was already migrated is
  a success (ADR-0002 decision 11).

      iex> alias Encryptor.Ecto.Migrator.Report
      iex> Report.ok?(Report.new(:dry_run))
      true
  """
  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{failure_count: 0}), do: true
  def ok?(%__MODULE__{}), do: false
end
