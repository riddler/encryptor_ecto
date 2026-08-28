defmodule Encryptor.Ecto.Migrator.Pass do
  @moduledoc """
  One field's pass: batches of rows, probed, rewritten, checkpointed.

  This is ADR-0002 decisions 4, 5 and 6 in one place. The engine
  (`Encryptor.Ecto.Migrator`) decides *what* to visit; a pass is *how* one
  `{schema, field, prefix}` is visited, which is also exactly the key its
  checkpoint row is written under.

  ## The order of operations for one row, and why it is that order

  1. **The source column is `NULL`** - nothing to do, and no key is touched.
  2. **Probe the target** (decision 5): attempt the `to` type's load on the
     bytes already in the target column. If it succeeds the row is in the
     target state and is skipped. Probe-first is what makes the whole pass
     idempotent by construction, which in turn is what makes the checkpoint a
     performance record rather than a correctness one.
  3. **Load through the source** (`from:`, ADR-0004 decision 2). A failure
     here is `:undecryptable`: neither side can read the row and an operator
     has to decide what that means.
  4. **Dump through the target**, under the row's own tenant.
  5. **Compare and swap** (decision 4): the update is conditional on the
     target column still holding the exact bytes step 2 read. Zero rows
     affected means the application wrote the row while the migrator was
     working on it - not an error, and not something to retry into a lost
     update. The row is re-probed and counted as concurrently migrated.

  A dry run does every one of those except the swap, which is what makes it an
  exact rehearsal including the decrypt and the encrypt cost (decision 7).

  ## The batch is the transaction, and a halt discards it

  Each batch is one transaction and the checkpoint row is written inside it,
  so the cursor and the rows it describes are consistent by construction.
  Under `on_error: :halt` - the default - a failing row rolls the batch back
  rather than committing the rows before it: committing them without a
  checkpoint is harmless, but committing them *with* one would advance the
  cursor past the failing row, and the next resume would skip the very row
  that stopped the pass. Probe-first makes redoing the discarded work free.

  ## Nothing here holds a value longer than a row

  The plaintext of one row exists between step 3 and step 4 and is never
  logged, inspected, put in an exception, or carried into the report (ADR-0002
  decision 11). The failures the report keeps carry the primary key, the
  schema, the field, and a reason already reduced to atoms and module names by
  `Encryptor.Ecto.Migrator.Source`.
  """

  alias Encryptor.Ecto.Migrator.Checkpoint
  alias Encryptor.Ecto.Migrator.Keyset
  alias Encryptor.Ecto.Migrator.Report
  alias Encryptor.Ecto.Migrator.RowTenant
  alias Encryptor.Ecto.Migrator.Source

  @typedoc "Everything one field's pass needs, resolved once before it starts."
  @type t :: %__MODULE__{
          repo: module(),
          plan: module(),
          schema: module(),
          source: String.t(),
          key: Keyset.key(),
          field: atom(),
          source_column: atom(),
          target_column: atom(),
          tenant: Encryptor.Ecto.Migrator.Plan.tenant(),
          tenant_column: atom() | nil,
          from_source: Source.resolved(),
          to: module(),
          to_arity: 1 | 3,
          to_params: term(),
          mode: Encryptor.Ecto.Migrator.mode(),
          batch_size: pos_integer(),
          on_error: :halt | :continue,
          prefix: String.t() | nil,
          checkpoint: :table | :none,
          checkpoint_table: String.t(),
          only_tenants: [String.t()] | nil,
          except_tenants: [String.t()],
          progress: (Report.t() -> any())
        }

  @enforce_keys [
    :repo,
    :plan,
    :schema,
    :source,
    :key,
    :field,
    :source_column,
    :target_column,
    :tenant,
    :tenant_column,
    :from_source,
    :to,
    :to_arity,
    :to_params,
    :mode,
    :batch_size,
    :on_error,
    :prefix,
    :checkpoint,
    :checkpoint_table,
    :only_tenants,
    :except_tenants,
    :progress
  ]
  defstruct @enforce_keys

  @doc """
  Runs one field to the end of its table, or to the row that halts it.

  Returns the report and `:ok`, or the report and `:halt` where a failure
  stopped the pass under `on_error: :halt`.
  """
  @spec run(t(), Report.t(), term()) :: {Report.t(), :ok | :halt}
  def run(%__MODULE__{} = pass, report, cursor) do
    case read_batch(pass, cursor) do
      [] ->
        {report, :ok}

      rows ->
        {report, status, last_id} = batch(pass, report, rows)
        report = cursor(report, pass, status, last_id)
        _ignored = pass.progress.(report)

        continue(pass, report, status, last_id, length(rows))
    end
  end

  # A halted batch rolled back, so its last id is not where the pass got to -
  # recording it would have the report disagree with the checkpoint about the
  # one number both exist to carry.
  @spec cursor(Report.t(), t(), :ok | :halt, term()) :: Report.t()
  defp cursor(report, _pass, :halt, _last_id), do: report

  defp cursor(report, pass, :ok, last_id),
    do: Report.put_cursor(report, pass.schema, pass.field, pass.prefix, last_id)

  @doc """
  The cursor this field resumes from, or `nil` for a full scan.

  `resume: false` returns `nil` without reading anything, which - because of
  probe-first - is always a legal thing to do.
  """
  @spec resume_cursor(t(), boolean()) :: term() | nil
  def resume_cursor(_pass, false), do: nil
  def resume_cursor(%__MODULE__{checkpoint: :none}, true), do: nil

  def resume_cursor(%__MODULE__{} = pass, true) do
    Checkpoint.fetch_cursor(pass.repo, pass.checkpoint_table, checkpoint_key(pass), pass.key)
  end

  @doc "Which checkpoint row this pass owns (ADR-0002 proposed amendment 6)."
  @spec checkpoint_key(t()) :: Checkpoint.key()
  def checkpoint_key(%__MODULE__{} = pass) do
    %{plan: pass.plan, schema: pass.schema, field: pass.field, prefix: pass.prefix}
  end

  # -- batching -------------------------------------------------------------

  @spec continue(t(), Report.t(), :ok | :halt, term(), non_neg_integer()) ::
          {Report.t(), :ok | :halt}
  defp continue(_pass, report, :halt, _last_id, _read), do: {report, :halt}

  defp continue(%__MODULE__{batch_size: size} = pass, report, :ok, last_id, read)
       when read >= size,
       do: run(pass, report, last_id)

  # A short batch is the last one: the query asked for `batch_size` rows in
  # key order and got fewer, so there is nothing above the cursor to visit.
  defp continue(_pass, report, :ok, _last_id, _read), do: {report, :ok}

  @spec read_batch(t(), term()) :: [list()]
  defp read_batch(pass, cursor) do
    pass.source
    |> Keyset.batch_query(
      pass.key,
      pass.source_column,
      pass.target_column,
      pass.tenant_column,
      cursor,
      pass.batch_size
    )
    |> filter_tenants(pass)
    |> pass.repo.all(query_opts(pass))
  end

  @spec filter_tenants(Ecto.Query.t(), t()) :: Ecto.Query.t()
  defp filter_tenants(query, %__MODULE__{tenant_column: nil}), do: query

  defp filter_tenants(query, pass) do
    Keyset.tenant_filter(query, pass.tenant_column, pass.only_tenants, pass.except_tenants)
  end

  @spec query_opts(t()) :: keyword()
  defp query_opts(%__MODULE__{prefix: nil}), do: []
  defp query_opts(%__MODULE__{prefix: prefix}), do: [prefix: prefix]

  # A dry run reads and computes but never opens a transaction and never
  # records a cursor: a rehearsal that wrote a checkpoint would let the real
  # run resume past rows it never wrote.
  @spec batch(t(), Report.t(), [list()]) :: {Report.t(), :ok | :halt, term()}
  defp batch(%__MODULE__{mode: :dry_run} = pass, report, rows) do
    {report, status} = rows(pass, report, rows)
    {report, status, last_id(rows)}
  end

  defp batch(%__MODULE__{mode: :write} = pass, report, rows) do
    last_id = last_id(rows)

    result =
      pass.repo.transaction(fn ->
        case rows(pass, report, rows) do
          {report, :ok} ->
            :ok = record(pass, report, last_id)
            report

          {report, :halt} ->
            pass.repo.rollback({:halted, report})
        end
      end)

    case result do
      {:ok, report} -> {report, :ok, last_id}
      {:error, {:halted, report}} -> {report, :halt, last_id}
    end
  end

  @spec record(t(), Report.t(), term()) :: :ok
  defp record(%__MODULE__{checkpoint: :none}, _report, _last_id), do: :ok

  defp record(pass, report, last_id) do
    Checkpoint.record(
      pass.repo,
      pass.checkpoint_table,
      checkpoint_key(pass),
      Checkpoint.render_cursor(last_id, pass.key),
      counts(report)
    )
  end

  # The checkpoint row carries the classification counts and the failure count
  # (decision 11), keyed by name so that a class added later - ADR-0002
  # proposed amendment 2's `:migratable_unverified` - appears without a column
  # being added for it.
  @spec counts(Report.t()) :: %{String.t() => non_neg_integer()}
  defp counts(report) do
    report.counts
    |> Map.new(fn {class, count} -> {Atom.to_string(class), count} end)
    |> Map.put("concurrent", report.concurrent)
    |> Map.put("failures", report.failure_count)
  end

  @spec last_id([list()]) :: term()
  defp last_id(rows), do: rows |> List.last() |> hd()

  @spec rows(t(), Report.t(), [list()]) :: {Report.t(), :ok | :halt}
  defp rows(pass, report, rows) do
    Enum.reduce_while(rows, {report, :ok}, fn row, {report, _status} ->
      case row(pass, report, row) do
        {report, :ok} -> {:cont, {report, :ok}}
        {report, :halt} -> {:halt, {report, :halt}}
      end
    end)
  end

  # -- one row --------------------------------------------------------------

  @spec row(t(), Report.t(), list()) :: {Report.t(), :ok | :halt}
  defp row(_pass, report, [_id, nil, _target | _tenant]),
    do: {Report.count(report, :null), :ok}

  defp row(pass, report, [id, source_value, target_value | tenant]) do
    tenant = row_tenant(tenant)

    RowTenant.with_tenant(tenant, fn ->
      if probe(pass, target_value) == :already_target do
        {Report.count(report, :already_target), :ok}
      else
        migrate(pass, report, id, source_value, target_value, tenant)
      end
    end)
  end

  @spec row_tenant([term()]) :: term()
  defp row_tenant([tenant]), do: tenant
  defp row_tenant([]), do: nil

  # The probe is a load attempt on the bytes already in the target column, and
  # its failure is the ordinary case rather than an event: a row that has not
  # been rewritten yet fails it every time. So every failure shape - a raise
  # from a type that raises by design (ADR-0001 decision 6), an `:error` from
  # an `Ecto.Type`, an off-contract return - is the same answer here, and none
  # of them reaches the report.
  @spec probe(t(), binary() | nil) :: :already_target | :not_target
  defp probe(_pass, nil), do: :not_target

  defp probe(pass, bytes) do
    case load_target(pass, bytes) do
      {:ok, _loaded} -> :already_target
      _other -> :not_target
    end
  rescue
    _exception -> :not_target
  end

  @spec load_target(t(), binary()) :: term()
  defp load_target(%__MODULE__{to_arity: 1} = pass, bytes), do: pass.to.load(bytes)

  defp load_target(%__MODULE__{to_arity: 3} = pass, bytes),
    do: pass.to.load(bytes, &Ecto.Type.load/2, pass.to_params)

  @spec migrate(t(), Report.t(), term(), binary(), binary() | nil, term()) ::
          {Report.t(), :ok | :halt}
  defp migrate(pass, report, id, source_value, target_value, tenant) do
    with {:ok, loaded} <- read_source(pass, source_value, tenant),
         {:ok, bytes} <- write_target(pass, loaded) do
      swap(pass, report, id, target_value, bytes)
    else
      {:error, reason} -> fail(pass, report, id, reason)
    end
  end

  @spec read_source(t(), binary(), term()) :: {:ok, term()} | {:error, term()}
  defp read_source(pass, value, tenant) do
    Source.load(pass.from_source, value, source_params(pass, tenant))
  end

  # ADR-0002 decision 3: the migrator constructs the params it hands both
  # sides, rather than reading them off a schema declaration. What a foreign
  # arity-3 `from:` module makes of them is its own business; the identifying
  # keys are here because a host's own legacy type may well need them, and the
  # tenant is here because a per-tenant legacy scheme could not read the row
  # without it.
  @spec source_params(t(), term()) :: map()
  defp source_params(pass, tenant) do
    %{
      schema: pass.schema,
      field: pass.field,
      table: pass.source,
      column: Atom.to_string(pass.source_column),
      tenant: tenant
    }
  end

  @spec write_target(t(), term()) :: {:ok, binary()} | {:error, term()}
  defp write_target(pass, value) do
    case dump_target(pass, value) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      {:ok, _other} -> {:error, :target_dumped_no_bytes}
      :error -> {:error, :target_dump_declined}
      {:error, reason} -> {:error, reason}
      _off_contract -> {:error, :target_off_contract}
    end
  rescue
    exception -> {:error, {:raised, exception.__struct__}}
  end

  @spec dump_target(t(), term()) :: term()
  defp dump_target(%__MODULE__{to_arity: 1} = pass, value), do: pass.to.dump(value)

  defp dump_target(%__MODULE__{to_arity: 3} = pass, value),
    do: pass.to.dump(value, &Ecto.Type.dump/2, pass.to_params)

  # -- the write ------------------------------------------------------------

  @spec swap(t(), Report.t(), term(), binary() | nil, binary()) :: {Report.t(), :ok | :halt}
  defp swap(%__MODULE__{mode: :dry_run}, report, _id, _previous, _bytes),
    do: {Report.count(report, :migratable), :ok}

  defp swap(pass, report, id, previous, bytes) do
    query = Keyset.swap_query(pass.source, pass.key, id, pass.target_column, previous)

    case pass.repo.update_all(query, [set: [{pass.target_column, bytes}]], query_opts(pass)) do
      {1, _returned} -> {Report.count(report, :migratable), :ok}
      {0, _returned} -> concurrent(pass, report, id)
    end
  end

  # Decision 4: zero rows affected means the application wrote this row while
  # the migrator held it. The row was counted `:migratable` when it was read,
  # and it is counted concurrent as well - the second count is about the
  # write, not about the row's state.
  @spec concurrent(t(), Report.t(), term()) :: {Report.t(), :ok | :halt}
  defp concurrent(pass, report, id) do
    report = Report.count(report, :migratable)

    if reprobe(pass, id) == :already_target do
      {Report.count_concurrent(report), :ok}
    else
      fail(pass, report, id, :concurrent_write_unreadable)
    end
  end

  @spec reprobe(t(), term()) :: :already_target | :not_target
  defp reprobe(pass, id) do
    query = Keyset.row_query(pass.source, pass.key, id, pass.target_column)

    case pass.repo.all(query, query_opts(pass)) do
      [[bytes]] -> probe(pass, bytes)
      _gone -> :not_target
    end
  end

  # `on_error: :continue` records the failure and finishes the pass, which
  # still exits non-zero: `Report.ok?/1` is about the failure count and not
  # about how the pass ended. There is no mode that skips a row silently.
  @spec fail(t(), Report.t(), term(), term()) :: {Report.t(), :ok | :halt}
  defp fail(pass, report, id, reason) do
    failure = %{schema: pass.schema, field: pass.field, id: id, reason: reason}
    {Report.record_failure(report, failure), status(pass.on_error)}
  end

  @spec status(:halt | :continue) :: :ok | :halt
  defp status(:halt), do: :halt
  defp status(:continue), do: :ok
end
