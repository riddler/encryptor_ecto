defmodule Encryptor.Ecto.Migrator do
  @moduledoc """
  Rewrites the ciphertext columns a plan names, against live traffic.

  ADR-0002. `run/2` takes a plan **module** - the one
  `Encryptor.Ecto.Migration` compiled - and an option list whose `:mode` is
  required, and returns a `t:Encryptor.Ecto.Migrator.Report.t/0` on both arms:

      MyApp.Encryption.CloakMigration
      |> Encryptor.Ecto.Migrator.run(mode: :dry_run)

      MyApp.Encryption.CloakMigration
      |> Encryptor.Ecto.Migrator.run(mode: :write, resume: true)

  The library function is the interface and the `mix` tasks (`ece-5qb`) are
  thin argument parsers over it, because a production host runs releases and a
  release has no Mix: a rotation reachable only from a developer's laptop
  against production credentials is the opposite of the control it is supposed
  to be (decision 1).

  ## What one pass does

  For each field of each rewrite, in the order the plan declares them, and one
  `{schema, field, prefix}` at a time:

    * rows are visited in primary-key order with keyset pagination - never
      `OFFSET`, which degrades quadratically and skips rows when the set
      shifts under it (decision 6);
    * every row is **probed** before it is rewritten, so the pass is
      idempotent by construction and the checkpoint is a performance record
      rather than a correctness one (decision 5);
    * every write is a **compare-and-swap** against the exact bytes the
      migrator read, so a row the application wrote in the meantime is counted
      rather than clobbered with a re-encryption of stale plaintext
      (decision 4);
    * every batch is one transaction, and the checkpoint row is written inside
      it (decision 6).

  `Encryptor.Ecto.Migrator.Pass` holds the per-row order and the reasoning
  behind it; this module decides what is visited and with what.

  ## There is no default mode

  Exactly one of `mode: :dry_run` or `mode: :write` (decision 7). A missing
  mode is an `ArgumentError`, not a dry run: making dry-run the default trains
  operators to add a flag they stop reading, and making write the default puts
  an irreversible pass one typo away.

  A dry run performs every read, every probe, every decrypt and every encrypt
  and discards the write, so it is an exact rehearsal of the work - including
  which rows fail to decrypt, how long it takes, and whether the checkpoint
  table is there.

  ## Options

  | Option | Default | |
  |---|---|---|
  | `:mode` | **required** | `:dry_run` or `:write` |
  | `:batch_size` | `500` | Rows per transaction |
  | `:resume` | `false` | Start after the recorded cursor |
  | `:prefix` | `nil` | The schema prefix to visit; the repo's default when absent |
  | `:checkpoint` | `:table` | `:none` runs with no checkpoint at all |
  | `:checkpoint_table` | `"encryptor_ecto_migration_checkpoints"` | |
  | `:on_error` | `:halt` | `:continue` records the failure and finishes |
  | `:only_tenants` | `nil` | Visit only these tenants |
  | `:except_tenants` | `[]` | Visit every tenant but these |
  | `:only` | `nil` | `[{Schema, [:field]}]`, to narrow the plan |
  | `:progress` | no-op | Called with the report after each batch |

  `:prefix` is singular and the plan carries none, per ADR-0002 proposed
  amendment 6: a prefix is a deployment-time placement decision rather than a
  fact about the schema, and a host with several prefixes loops `run/2` over
  its own list. No mode enumerates prefixes and no database catalog is read to
  find them.

  `checkpoint: :none` with `resume: true` is an `ArgumentError`: resuming from
  a checkpoint that was never written is a request with no meaning.

  ## Which failures are exceptions and which are reports

  A run that **cannot start** raises: an unknown option, a missing mode, a
  schema whose primary key cannot be paged over, a tenant filter against a
  rewrite that has no tenant column, a missing checkpoint table. None of those
  is about rows, and none of them is improved by being handed back as an empty
  report.

  A run that started reports. `{:error, report}` means the pass found rows an
  operator has to decide about; the report says which, and carries everything
  the pass did before it stopped (decision 11). There is no mode that skips a
  row silently, and no arm that exits zero with failures recorded.

  ## What lives elsewhere

  `verify/2` and the SQL census are `ece-7fr`; the `mix` task family is
  `ece-5qb`; `source_authenticated:` and `validate:` - and with them the
  `:migratable_unverified` class - are `ece-4mg`. The report is built so that
  adding that class is additive (`Encryptor.Ecto.Migrator.Report.classes/0`).
  """

  alias Encryptor.Ecto.Migrator.Checkpoint
  alias Encryptor.Ecto.Migrator.Keyset
  alias Encryptor.Ecto.Migrator.Pass
  alias Encryptor.Ecto.Migrator.Plan
  alias Encryptor.Ecto.Migrator.Report
  alias Encryptor.Ecto.Migrator.RowTenant

  @typedoc "The mode a run performs. There is no default (decision 7)."
  @type mode :: :dry_run | :write

  @type opts :: [
          mode: mode(),
          batch_size: pos_integer(),
          resume: boolean(),
          prefix: String.t() | nil,
          checkpoint: :table | :none,
          checkpoint_table: String.t(),
          on_error: :halt | :continue,
          only_tenants: [String.t()] | nil,
          except_tenants: [String.t()],
          only: [{module(), [atom()]}] | nil,
          progress: (Report.t() -> any())
        ]

  @typep options :: %{
           mode: mode(),
           batch_size: pos_integer(),
           resume: boolean(),
           prefix: String.t() | nil,
           checkpoint: :table | :none,
           checkpoint_table: String.t(),
           on_error: :halt | :continue,
           only_tenants: [String.t()] | nil,
           except_tenants: [String.t()],
           only: [{module(), [atom()]}] | nil,
           progress: (Report.t() -> any())
         }

  @known_options [
    :mode,
    :batch_size,
    :resume,
    :prefix,
    :checkpoint,
    :checkpoint_table,
    :on_error,
    :only_tenants,
    :except_tenants,
    :only,
    :progress
  ]

  @doc """
  Runs a plan, in exactly one of the two modes.

  Returns `{:ok, report}` when no row needed an operator's decision and
  `{:error, report}` when one did. Raises before visiting anything when the
  run cannot start - see "Which failures are exceptions and which are
  reports".
  """
  @spec run(module(), opts()) :: {:ok, Report.t()} | {:error, Report.t()}
  def run(plan_module, opts) do
    plan = plan!(plan_module)
    options = options!(opts)
    passes = passes!(plan_module, plan, options)

    :ok = preflight!(plan.repo, options)

    passes
    |> report(options)
    |> Report.finish()
    |> result()
  end

  @spec report([Pass.t()], options()) :: Report.t()
  defp report(passes, options) do
    {report, _status} =
      Enum.reduce_while(passes, {Report.new(options.mode), :ok}, fn pass, {report, _status} ->
        cursor = Pass.resume_cursor(pass, options.resume)

        case Pass.run(pass, report, cursor) do
          {report, :ok} -> {:cont, {report, :ok}}
          {report, :halt} -> {:halt, {report, :halt}}
        end
      end)

    report
  end

  @spec result(Report.t()) :: {:ok, Report.t()} | {:error, Report.t()}
  defp result(report) do
    if Report.ok?(report), do: {:ok, report}, else: {:error, report}
  end

  # -- the plan -------------------------------------------------------------

  @spec plan!(module()) :: Plan.t()
  defp plan!(plan_module) when is_atom(plan_module) do
    if Code.ensure_loaded?(plan_module) and function_exported?(plan_module, :__plan__, 0) do
      plan_module.__plan__()
    else
      raise ArgumentError, not_a_plan_message(plan_module)
    end
  end

  defp plan!(other), do: raise(ArgumentError, not_a_plan_message(other))

  @spec passes!(module(), Plan.t(), options()) :: [Pass.t()]
  defp passes!(plan_module, plan, options) do
    plan.rewrites
    |> Enum.flat_map(&fields(&1, options.only))
    |> Enum.map(fn {rewrite, field} -> pass!(plan_module, plan, rewrite, field, options) end)
  end

  @spec fields(Plan.rewrite(), [{module(), [atom()]}] | nil) :: [{Plan.rewrite(), tuple()}]
  defp fields(rewrite, nil), do: Enum.map(rewrite.fields, &{rewrite, &1})

  defp fields(rewrite, only) do
    case List.keyfind(only, rewrite.schema, 0) do
      nil ->
        []

      {_schema, names} ->
        for {name, _spec} = field <- rewrite.fields, name in names, do: {rewrite, field}
    end
  end

  @spec pass!(module(), Plan.t(), Plan.rewrite(), {atom(), keyword()}, options()) :: Pass.t()
  defp pass!(plan_module, plan, rewrite, {field, spec}, options) do
    key = key!(rewrite.schema)
    target_column = Keyword.get(spec, :into) || field
    to = Keyword.fetch!(spec, :to)
    {arity, params} = target!(to, rewrite, target_column)

    %Pass{
      repo: plan.repo,
      plan: plan_module,
      schema: rewrite.schema,
      source: Keyset.source(rewrite.schema),
      key: key,
      field: field,
      source_column: field,
      target_column: target_column,
      tenant: rewrite.tenant,
      tenant_column: tenant_column!(rewrite, options),
      from_source: Keyword.fetch!(spec, :source),
      to: to,
      to_arity: arity,
      to_params: params,
      mode: options.mode,
      batch_size: options.batch_size,
      on_error: options.on_error,
      prefix: options.prefix,
      checkpoint: options.checkpoint,
      checkpoint_table: options.checkpoint_table,
      only_tenants: options.only_tenants,
      except_tenants: options.except_tenants,
      progress: options.progress
    }
  end

  @spec key!(module()) :: Keyset.key()
  defp key!(schema) do
    case Keyset.primary_key(schema) do
      {:ok, key} -> key
      {:error, message} -> raise ArgumentError, message
    end
  end

  # A tenant filter is a `where` on the tenant column (decision 11), so a
  # rewrite that resolves its tenant any other way has no column to filter on.
  # Refused rather than ignored: a run that quietly visited every tenant of a
  # `tenant :none` rewrite while the operator believed it was scoped to one is
  # the failure the filter exists to prevent.
  @spec tenant_column!(Plan.rewrite(), options()) :: atom() | nil
  defp tenant_column!(%{tenant: {:column, column}}, _options), do: column

  defp tenant_column!(rewrite, options) do
    if filtering?(options) do
      raise ArgumentError, unfilterable_message(rewrite.schema, rewrite.tenant)
    end

    nil
  end

  @spec filtering?(options()) :: boolean()
  defp filtering?(options), do: options.only_tenants != nil or options.except_tenants != []

  # -- the target type ------------------------------------------------------

  # The migrator constructs both sides' params itself (decision 3), which is
  # what makes `from:` and `to:` naming the same module with different context
  # expressible at all. The tenant is replaced by the plan's own strategy: a
  # `tenant_from` rewrite resolves per row through
  # `Encryptor.Ecto.Migrator.RowTenant`, never through the process scope the
  # type would otherwise read.
  @spec target!(module(), Plan.rewrite(), atom()) :: {1 | 3, term()}
  defp target!(to, rewrite, target_column) do
    _loaded = Code.ensure_loaded(to)

    cond do
      function_exported?(to, :load, 3) -> {3, target_params(to, rewrite, target_column)}
      function_exported?(to, :load, 1) -> {1, nil}
      true -> raise ArgumentError, unwritable_target_message(rewrite.schema, to)
    end
  end

  @spec target_params(module(), Plan.rewrite(), atom()) :: term()
  defp target_params(to, rewrite, target_column) do
    params = to.init(schema: rewrite.schema, field: target_column)

    if ours?(params) do
      Map.put(params, :tenant, resolver(rewrite.tenant))
    else
      params
    end
  end

  # A foreign `Ecto.ParameterizedType` gets its own params untouched: its
  # `:tenant` key, if it has one, means whatever that module decided it means,
  # and writing ours over it would be this package reaching into a contract it
  # does not own.
  #
  # Recognised by the frozen params rather than by the
  # `__encryptor_ecto__/1` marker `Encryptor.Ecto.Declarations` uses, and the
  # reason is worth stating: today that marker is defined by
  # `Encryptor.Ecto.Binary`'s `__using__` alone, so a field declared through
  # `Encryptor.Ecto.String` or `Encryptor.Ecto.Map` does not carry it. Adding
  # it there would also change which fields `Declarations.check_unique!/1`
  # sees, which is ADR-0001's contract and not this record's to widen. The
  # shape checked here is the whole of what `Encryptor.Ecto.Binary.init/2`
  # freezes - six keys, `:vault` and `:legacy` among them - which an unrelated
  # parameterized type does not carry by accident.
  @our_params [:vault, :tenant, :context, :table, :column, :legacy]

  @spec ours?(term()) :: boolean()
  defp ours?(params) when is_map(params),
    do: Enum.all?(@our_params, &Map.has_key?(params, &1))

  defp ours?(_params), do: false

  @spec resolver(Plan.tenant()) :: module() | :none
  defp resolver({:column, _column}), do: RowTenant
  defp resolver(:none), do: :none
  defp resolver(module) when is_atom(module), do: module

  # -- the options ----------------------------------------------------------

  @spec options!(term()) :: options()
  defp options!(opts) do
    opts = keyword!(opts)
    unknown!(opts)

    options = %{
      mode: mode!(opts),
      batch_size: batch_size!(opts),
      resume: boolean!(opts, :resume, false),
      prefix: prefix!(opts),
      checkpoint: one_of!(opts, :checkpoint, [:table, :none], :table),
      checkpoint_table: checkpoint_table!(opts),
      on_error: one_of!(opts, :on_error, [:halt, :continue], :halt),
      only_tenants: tenants!(opts, :only_tenants, nil),
      except_tenants: tenants!(opts, :except_tenants, []),
      only: only!(opts),
      progress: progress!(opts)
    }

    if options.checkpoint == :none and options.resume do
      raise ArgumentError, resume_without_checkpoint_message()
    end

    options
  end

  @spec keyword!(term()) :: keyword()
  defp keyword!(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError, "Encryptor.Ecto.Migrator.run/2 expects a keyword list of options"
    end
  end

  @spec unknown!(keyword()) :: :ok
  defp unknown!(opts) do
    case Keyword.keys(opts) -- @known_options do
      [] -> :ok
      unknown -> raise ArgumentError, unknown_options_message(unknown)
    end
  end

  @spec mode!(keyword()) :: mode()
  defp mode!(opts) do
    case Keyword.fetch(opts, :mode) do
      {:ok, mode} when mode in [:dry_run, :write] -> mode
      {:ok, other} -> raise ArgumentError, bad_mode_message(other)
      :error -> raise ArgumentError, missing_mode_message()
    end
  end

  @spec batch_size!(keyword()) :: pos_integer()
  defp batch_size!(opts) do
    case Keyword.get(opts, :batch_size, 500) do
      size when is_integer(size) and size > 0 ->
        size

      other ->
        raise ArgumentError, "batch_size: expects a positive integer, got #{inspect(other)}"
    end
  end

  @spec boolean!(keyword(), atom(), boolean()) :: boolean()
  defp boolean!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> value
      other -> raise ArgumentError, "#{key}: expects true or false, got #{inspect(other)}"
    end
  end

  @spec prefix!(keyword()) :: String.t() | nil
  defp prefix!(opts) do
    case Keyword.get(opts, :prefix) do
      nil -> nil
      prefix when is_binary(prefix) and prefix != "" -> prefix
      other -> raise ArgumentError, "prefix: expects a non-empty string, got #{inspect(other)}"
    end
  end

  @spec checkpoint_table!(keyword()) :: String.t()
  defp checkpoint_table!(opts) do
    case Keyword.get(opts, :checkpoint_table, Checkpoint.default_table()) do
      table when is_binary(table) and table != "" ->
        table

      other ->
        raise ArgumentError, "checkpoint_table: expects a table name, got #{inspect(other)}"
    end
  end

  @spec one_of!(keyword(), atom(), [atom()], atom()) :: atom()
  defp one_of!(opts, key, allowed, default) do
    value = Keyword.get(opts, key, default)

    if value in allowed do
      value
    else
      raise ArgumentError, "#{key}: expects one of #{inspect(allowed)}, got #{inspect(value)}"
    end
  end

  @spec tenants!(keyword(), atom(), [String.t()] | nil) :: [String.t()] | nil
  defp tenants!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      nil ->
        nil

      list when is_list(list) ->
        assert_tenant_list!(list, key)

      other ->
        raise ArgumentError, "#{key}: expects a list of tenant identifiers, got #{inspect(other)}"
    end
  end

  @spec assert_tenant_list!([term()], atom()) :: [String.t()]
  defp assert_tenant_list!(list, key) do
    if Enum.all?(list, &is_binary/1) do
      list
    else
      raise ArgumentError, "#{key}: expects a list of tenant identifiers as strings"
    end
  end

  @spec only!(keyword()) :: [{module(), [atom()]}] | nil
  defp only!(opts) do
    case Keyword.get(opts, :only) do
      nil -> nil
      list when is_list(list) -> assert_only!(list)
      other -> raise ArgumentError, only_message(other)
    end
  end

  @spec assert_only!([term()]) :: [{module(), [atom()]}]
  defp assert_only!(list) do
    valid? =
      Enum.all?(list, fn
        {schema, fields} when is_atom(schema) and is_list(fields) -> Enum.all?(fields, &is_atom/1)
        _other -> false
      end)

    if valid?, do: list, else: raise(ArgumentError, only_message(list))
  end

  @spec progress!(keyword()) :: (Report.t() -> any())
  defp progress!(opts) do
    case Keyword.get(opts, :progress, fn _report -> :ok end) do
      fun when is_function(fun, 1) ->
        fun

      other ->
        raise ArgumentError, "progress: expects a one-argument function, got #{inspect(other)}"
    end
  end

  # -- preflight ------------------------------------------------------------

  # The checkpoint table is checked in **both** modes, so that a dry run is a
  # rehearsal of the whole thing rather than of everything except the part
  # that stops the real run on its first batch (ADR-0002 decision 9 and
  # proposed amendment 5).
  @spec preflight!(module(), options()) :: :ok
  defp preflight!(_repo, %{checkpoint: :none}), do: :ok

  defp preflight!(repo, options) do
    case Checkpoint.preflight(repo, options.checkpoint_table) do
      :ok -> :ok
      {:error, message} -> raise ArgumentError, message
    end
  end

  # -- the messages ---------------------------------------------------------

  defp not_a_plan_message(given) do
    "Encryptor.Ecto.Migrator.run/2 expects a plan module - one that " <>
      "`use Encryptor.Ecto.Migration` - and was given #{inspect(given)}, " <>
      "which exports no `__plan__/0`. The plan is the unit of work " <>
      "(ADR-0002 decision 2); there is no path that takes a schema or a " <>
      "list of fields instead."
  end

  defp missing_mode_message do
    "Encryptor.Ecto.Migrator.run/2 requires `mode:`, and there is no default " <>
      "(ADR-0002 decision 7): `mode: :dry_run` rehearses the whole pass and " <>
      "discards every write, `mode: :write` performs it. Making dry-run the " <>
      "default would train operators to add a flag they stop reading; making " <>
      "write the default would put an irreversible pass one typo away."
  end

  defp bad_mode_message(given) do
    "mode: expects :dry_run or :write, got #{inspect(given)}."
  end

  defp resume_without_checkpoint_message do
    "`checkpoint: :none` and `resume: true` cannot be combined: resuming " <>
      "from a checkpoint that was never written is a request with no " <>
      "meaning. Without a checkpoint every run is a full scan, which " <>
      "probe-first idempotence (ADR-0002 decision 5) makes correct."
  end

  defp unknown_options_message(unknown) do
    "Encryptor.Ecto.Migrator.run/2 was given unknown options " <>
      "#{inspect(unknown)}. Known options: #{inspect(@known_options)}."
  end

  defp only_message(given) do
    "only: expects a list of `{Schema, [:field, :field]}` pairs, got " <>
      "#{inspect(given)}."
  end

  defp unfilterable_message(schema, tenant) do
    "a tenant filter was given, but `rewrite #{inspect(schema)}` resolves " <>
      "its tenant as #{inspect(tenant)} rather than from a column, so there " <>
      "is nothing to filter on. `only_tenants:` and `except_tenants:` are a " <>
      "`where` on the tenant column (ADR-0002 decision 11); narrow the run " <>
      "with `only:` instead, or give the rewrite a `tenant_from`."
  end

  defp unwritable_target_message(schema, to) do
    "`rewrite #{inspect(schema)}` names #{inspect(to)} as a `to:` type, but " <>
      "that module exports neither `load/3` nor `load/1` here. A plan that " <>
      "compiled cannot normally reach this: check that the module is in the " <>
      "release the pass is running from."
  end
end
