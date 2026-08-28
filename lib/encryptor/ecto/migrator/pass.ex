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
  3. **Load through the source** (`from:`, ADR-0004 decision 2), and, where
     the field declared one, apply `validate:` to what it loaded. A failure
     of either is `:undecryptable`: the row cannot be read in a way anything
     trusts, and an operator has to decide what that means.
  4. **Dump through the target**, under the row's own tenant.
  5. **Compare and swap** (decision 4): the update is conditional on the
     target column still holding the exact bytes step 2 read. Zero rows
     affected means the application wrote the row while the migrator was
     working on it - not an error, and not something to retry into a lost
     update. The row is re-probed and counted as concurrently migrated.

  A dry run does every one of those except the swap, which is what makes it an
  exact rehearsal including the decrypt and the encrypt cost (decision 7).

  ## The third mode reads and stops

  `mode: :verify` (decision 10) does steps 1 to 3 and stops there. It does not
  dump, because the encrypt would produce bytes nothing writes, and the
  classification does not need them: decision 7 defines `:migratable` as the
  probe failing and the `from` load succeeding, which step 3 has already
  settled. It never opens a transaction and never records a checkpoint, for
  the same reason a dry run does not.

  A verification also visits differently. `sample: n` reads one random `n`
  rows per field instead of paging the table (`Keyset.sample_query/6`, which
  records why the sample is random rather than the first `n` in key order),
  and records no cursor: a random draw has no "how far it got" to report.

  ## What an unauthenticated source changes here

  A field that declared `source_authenticated: false` (ADR-0004 decision 3)
  has its migratable rows counted `:migratable_unverified` instead - the same
  work, a different word in the evidence, because no authentication tag ever
  confirmed those bytes. The class is a property of the field rather than of
  the row, so it is decided once per pass and applied wherever a row would
  otherwise be counted `:migratable`, the concurrent-write arm included.

  `validate:` is the host's own check on the loaded plaintext, run before the
  value is re-encrypted (decision 3b) and in every mode, because a
  verification that skipped it would call a row migratable that a write would
  refuse. It runs against the loaded value and never sees the report: a
  rejection is `:undecryptable` with the reason `:validate_rejected`, and a
  raise from it is `{:raised, Module}` like any other, so neither arm can put
  a plaintext anywhere.

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

  @typedoc """
  Everything one field's pass needs, resolved once before it starts.

  `:validate` is typed by what it may *return* rather than by what it is
  contracted to return. The contract is
  `t:Encryptor.Ecto.Migration.field_spec/0`'s `(term() -> boolean())`; this is
  a function the host wrote, arriving through a compiled plan, and a pass that
  declared the contract here would be asserting a fact about someone else's
  code that nothing checked. `validate/2` checks it instead.
  """
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
          source_authenticated: boolean(),
          validate: (term() -> term()) | nil,
          to: module(),
          to_arity: 1 | 3,
          to_params: term(),
          mode: Encryptor.Ecto.Migrator.pass_mode(),
          batch_size: pos_integer(),
          sample: pos_integer() | :all,
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
    :source_authenticated,
    :validate,
    :to,
    :to_arity,
    :to_params,
    :mode,
    :batch_size,
    :sample,
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
  def run(%__MODULE__{sample: size} = pass, report, _cursor) when is_integer(size) do
    case read_sample(pass, size) do
      [] ->
        {report, :ok}

      rows ->
        {report, status} = rows(pass, report, rows)
        _ignored = pass.progress.(report)

        {report, status}
    end
  end

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

  @spec read_sample(t(), pos_integer()) :: [list()]
  defp read_sample(pass, size) do
    pass.source
    |> Keyset.sample_query(
      pass.key,
      pass.source_column,
      pass.target_column,
      pass.tenant_column,
      size
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
  # run resume past rows it never wrote. A verification is read-only for the
  # stronger reason that it is read-only, and takes the same arm.
  @spec batch(t(), Report.t(), [list()]) :: {Report.t(), :ok | :halt, term()}
  defp batch(%__MODULE__{mode: mode} = pass, report, rows) when mode in [:dry_run, :verify] do
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

  # ADR-0002 proposed amendment 2: which of the two migratable classes this
  # field's rows are counted under. A property of the field, so it is the same
  # answer for every row of the pass.
  @spec migratable(t()) :: Report.class()
  defp migratable(%__MODULE__{source_authenticated: false}), do: :migratable_unverified
  defp migratable(_pass), do: :migratable

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

  # A verification stops at the source load. Decision 7's `:migratable` is
  # "the probe failed and the `from` load succeeded", so the class is already
  # decided here; dumping as well would spend the encrypt to learn nothing and
  # would let a `to:` module's dump failure be reported as a row neither side
  # can read, which is not what `:undecryptable` means.
  @spec migrate(t(), Report.t(), term(), binary(), binary() | nil, term()) ::
          {Report.t(), :ok | :halt}
  defp migrate(%__MODULE__{mode: :verify} = pass, report, id, source_value, _target, tenant) do
    case load_source(pass, source_value, tenant) do
      {:ok, _loaded} -> {Report.count(report, migratable(pass)), :ok}
      {:error, reason} -> fail(pass, report, id, reason)
    end
  end

  defp migrate(pass, report, id, source_value, target_value, tenant) do
    with {:ok, loaded} <- load_source(pass, source_value, tenant),
         {:ok, bytes} <- write_target(pass, loaded) do
      swap(pass, report, id, target_value, bytes)
    else
      {:error, reason} -> fail(pass, report, id, reason)
    end
  end

  # The read and the host's check are one step: nothing downstream should have
  # to remember to validate, and a value that fails the check is not a value
  # this pass has read successfully.
  @spec load_source(t(), binary(), term()) :: {:ok, term()} | {:error, term()}
  defp load_source(pass, value, tenant) do
    with {:ok, loaded} <- read_source(pass, value, tenant),
         :ok <- validate(pass, loaded) do
      {:ok, loaded}
    end
  end

  # ADR-0004 decision 3b. The loaded value goes to the host's function and
  # nowhere else: the reason carries `:validate_rejected` or the raising
  # module's name, never what was rejected (ADR-0002 decision 11).
  #
  # A return that is neither `true` nor `false` is a failure rather than a
  # truthy pass, for the same reason `write_target/2` refuses an off-contract
  # dump: decision 3b's contract is `(term() -> boolean())`, and a host check
  # that answered `{:error, :no_hash_column}` would otherwise read as "valid"
  # and launder the row it was written to catch. Matching also keeps the
  # rejected value out of the reason, which an `if` over an arbitrary term
  # makes easy to lose.
  @spec validate(t(), term()) :: :ok | {:error, term()}
  defp validate(%__MODULE__{validate: nil}, _loaded), do: :ok

  defp validate(%__MODULE__{validate: fun}, loaded) do
    case fun.(loaded) do
      true -> :ok
      false -> {:error, :validate_rejected}
      _off_contract -> {:error, :validate_off_contract}
    end
  rescue
    exception -> {:error, {:raised, exception.__struct__}}
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
  defp swap(%__MODULE__{mode: :dry_run} = pass, report, _id, _previous, _bytes),
    do: {Report.count(report, migratable(pass)), :ok}

  defp swap(pass, report, id, previous, bytes) do
    query = Keyset.swap_query(pass.source, pass.key, id, pass.target_column, previous)

    case pass.repo.update_all(query, [set: [{pass.target_column, bytes}]], query_opts(pass)) do
      {1, _returned} -> {Report.count(report, migratable(pass)), :ok}
      {0, _returned} -> concurrent(pass, report, id)
    end
  end

  # Decision 4: zero rows affected means the application wrote this row while
  # the migrator held it. The row was counted `:migratable` when it was read,
  # and it is counted concurrent as well - the second count is about the
  # write, not about the row's state.
  @spec concurrent(t(), Report.t(), term()) :: {Report.t(), :ok | :halt}
  defp concurrent(pass, report, id) do
    report = Report.count(report, migratable(pass))

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
