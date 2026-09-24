defmodule Encryptor.Ecto.Migrator.Pass do
  @moduledoc """
  One field's pass: batches of rows, probed, rewritten, checkpointed.

  This is ADR-0002 decisions 4, 5 and 6 in one place. The engine
  (`Encryptor.Ecto.Migrator`) decides *what* to visit; a pass is *how* one
  `{schema, field, prefix}` is visited, which is also exactly the key its
  checkpoint row is written under.

  ## The order of operations for one row, and why it is that order

  1. **The source column is `NULL`** - nothing to do, and no key is touched.
  2. **Probe the target** (decision 5): decide whether the bytes already in
     the target column are in the target state, and skip the row if they are.
     Probe-first is what makes the whole pass idempotent by construction,
     which in turn is what makes the checkpoint a performance record rather
     than a correctness one. See "Two ways to probe" below for which of the
     two answers the question.
  3. **Load through the source** (`from:`, ADR-0004 decision 2), and, where
     the field declared one, apply `validate:` to what it loaded. A failure
     of either is `:undecryptable`: the row cannot be read in a way anything
     trusts, and an operator has to decide what that means.
  4. **Dump through the target**, under the row's own scope.
  5. **Compare and swap** (decision 4): the update is conditional on the
     target column still holding the exact bytes step 2 read. Zero rows
     affected means the application wrote the row while the migrator was
     working on it - not an error, and not something to retry into a lost
     update. The row is re-probed and counted as concurrently migrated.

  A dry run does every one of those except the swap, which is what makes it an
  exact rehearsal including the decrypt and the encrypt cost (decision 7).

  ## Two ways to probe, and when the cheap one is allowed

  Decision 5 wrote the probe as a load attempt: call the `to` type's load on
  the stored bytes, and read success as "already in the target state". That is
  one decrypt per already-migrated row, and on a table that is mostly migrated
  - a resumed pass, a second run, a scheduled re-run - it is the whole cost of
  the pass. The same decision says the probe short-circuits to a header
  inspection wherever upstream can classify a message without a key, which
  assumption A9 resolved at acceptance: `Encryptor.Message.describe/1` reads a
  message's encryption context keylessly.

  So a pass whose target is one of this package's own vault-backed types
  probes by reading the header, in two steps.

  **Step one is a comparison against what the target declares.** The context
  the message claims must equal the context that target's declaration writes -
  the vault's static pairs, the declared `"table"` and `"column"`, and
  whatever `:context` added, which `Encryptor.Ecto.Binary.declared_context/1`
  composes once rather than twice - and the algorithm suite the message names
  must equal the one the target's vault is configured to write. The
  `"tenant_ref"` pair the vault derives is compared for presence and not for
  value: which scope a row belongs to is not what the probe asks.

  Comparing the *whole* context rather than merely parsing the header is what
  keeps a context-change rewrite correct - a rewrite whose `from:` is one of
  this package's own declarations, whether that is the same module as `to:`
  under another vault or the earlier declaration a two-declaration edit keeps
  (`Encryptor.Ecto.Migration`'s "Silence is allowed only where authentication
  is provable"). Both sides of that rewrite write well-formed messages of this
  package's format, and a probe that read no further than "it parses" would
  call every unrewritten row already migrated and silently do nothing.

  **Step two is a proof, because a context and a suite do not identify a
  key.** ADR-0002's R3 rewrites a column whose "format, algorithm, library, or
  encryption context" changes, and two of those - a different vault over the
  same declared context, a re-keyed one - leave every compared pair identical
  while the bytes are still the source's. What separates them is the wrapping
  key, which the header names as each encrypted data key's
  `{provider_id, key_name}` and which nothing keyless can predict: the name is
  a keyed derivation the provider mints (`Encryptor.Key.Aes`), so the pass
  cannot compute the one the target would use for a row it has not written.

  It can prove one instead. The first row of a batch claiming a given
  `{suite, encrypted data keys}` identity is **loaded** rather than believed,
  and only an identity a load has just proven the target reads is allowed to
  short-circuit the rest of that batch. A source row's identity is never
  proven - its load fails, exactly as it does on `main` - so an R3 rewrite
  whose two sides differ only in vault, key or suite rewrites every row it
  used to rewrite. The saving is per batch rather than per row: one decrypt
  for each distinct wrapping key a batch touches, instead of one per
  already-migrated row.

  The proof is sound because a key name is bound to its material forever -
  `Encryptor.Key.Aes` makes reusing one for different material a defect,
  since it silently breaks every message already written under it. Two
  messages with the same identity and the same context are therefore
  readable by the same key, and the first one's load answers for both.

  The memo lives in the batch's own fold and nowhere else. It is a pure
  optimization: dropping it costs decrypts, never correctness, which is why
  it is scoped to the smallest thing that still pays - a batch is one
  transaction, and a pass that resumes has no use for what a previous
  transaction proved.

  `describe/1`'s answer is an unverified claim by whoever wrote the bytes, and
  that is the right strength here: nothing downstream of the probe is an
  authorization decision (`Encryptor.Message`'s own warning). The worst a
  forged header can do is have the pass leave a row alone. That is not what
  the load probe would have done with the same row - a load that fails sends
  the row to the source reader, which rewrites it from the intact source - so
  the header probe trades a rewrite the load probe would have performed for
  the decrypts it saves, and the row waits until a `mode: :verify` run, which
  always loads, reports it.

  Two cases keep the load attempt:

    * a **foreign target** - a plain `Ecto.Type`, someone else's
      parameterized type, or a vault that is not running when the pass is
      built - because there is no header this package can read a claim out of;
    * a **verification** (`mode: :verify`), because opening the bytes is the
      whole of what decision 10 makes it the authoritative answer *for*. A
      verification that classified from headers would be a cheap census
      wearing the acceptance test's name, and the cheap census already exists
      (`Encryptor.Ecto.Migrator.Census`).

  Both ways are the one `probe/3` below, which is what
  `Encryptor.Ecto.Migrator.verify/2` means by borrowing the pass's probe
  rather than reimplementing it.

  ## What a rotation adds, and nothing else

  A rotation - `Encryptor.Ecto.Migrator.run/2` with `writing_key:` set - is
  the one pass whose `from:` and `to:` are a single declaration under a single
  vault, and every pair step one compares is therefore identical across it.
  Both probes would answer "already in the target state" for a row written
  under the outgoing key version, the load probe because that version still
  decrypts (ADR-0002 A11 and A12) and the header probe because a key version
  is not one of the three things step one compares.

  The version comparison is the only thing rotation adds. It is one predicate
  inside the header probe's claim check, before the claim is handed on: a row
  is in the target state when every encrypted data key the header names claims
  the `writing_key:` name, and a row claiming any other name makes `claimed/3`
  answer `:no` and is rewritten without a load being attempted. Nothing else
  moves. `against_proof/4` is untouched and needs no touching, because a
  stale-version header makes a different identity and so never reaches a proof
  entry a current-version row made. `load_probe/2` is untouched, and is not
  consulted for a row the comparison has already rejected, so a rotation costs
  no decrypt it did not already cost. The cursor, the batching, the
  concurrent-write re-probe and the write path are untouched too.

  A rotation adds no class to the report either: a row whose header names
  another key is `:migratable`, because the probe failed and the `from` load
  succeeded - which by A11 it does.

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

  ## A folded blind index rides the same write

  A field whose spec names `index:` (ADR-0004's Note of 2026-09-24, answering
  its open question Q1) adds one step between 4 and 5: the index value is
  computed from the value step 3 loaded - the plaintext already in hand, so no
  second decrypt - by the computation `Encryptor.Ecto.BlindIndex.Value.compute!/3`
  performs for `Encryptor.Ecto.BlindIndex.put_index/3`, run over the pass's own
  field params and asked with `:dump` under the row's own scope. Step 5's
  compare-and-swap then sets the index column in the same `UPDATE` as the
  ciphertext, so the two land together or, on a lost swap, not at all.

  A dry run computes it and discards it, as it does the dump. A verification
  does not compute it: it stops at step 3. A row the probe skips is not
  loaded, so its index is left as the application wrote it.

  A failure computing it is `{:blind_index, column, reason}`, with the reason
  reduced to a module name exactly as a raising `to:` dump is, so the report
  says which of the rewrite and the index failed and carries neither the
  plaintext nor an index value.

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

  alias Encryptor.Context
  alias Encryptor.Ecto.BlindIndex.Value
  alias Encryptor.Ecto.Migrator.Checkpoint
  alias Encryptor.Ecto.Migrator.Keyset
  alias Encryptor.Ecto.Migrator.Report
  alias Encryptor.Ecto.Migrator.RowScope
  alias Encryptor.Ecto.Migrator.Source
  alias Encryptor.Message

  @typedoc """
  What a message written by this field's target says about itself, keylessly.

  `:context` is every pair such a message carries except `"tenant_ref"`, and
  `:scope_ref?` is whether it carries that one - the value is the vault's
  derivation of a scope selector and is never compared. `:suite` is the
  algorithm suite that target's vault is configured to write. Resolved once,
  before the pass starts, by `Encryptor.Ecto.Migrator`; `nil` there means the
  probe cannot be answered from a header and the load attempt runs instead.
  """
  @type target_header :: %{
          context: %{optional(String.t()) => String.t()},
          scope_ref?: boolean(),
          suite: non_neg_integer()
        }

  @typedoc """
  The wrapping-key identity a message claims: the algorithm suite it names,
  and the `{provider_id, key_name}` pair of every encrypted data key in it, in
  the order the header carries them.

  Two messages with the same identity are wrapped by the same key or by a
  provider that has broken `Encryptor.Key.Aes`'s name-is-bound-to-material
  rule. That is what lets one load answer for both - see the moduledoc's "Two
  ways to probe".
  """
  @type identity :: %{suite: non_neg_integer(), keys: [map()]}

  @typedoc """
  A blind index folded into this pass: the column the pass writes, the
  declaration its value is computed through, and the encrypted field's params
  with the plan's scope strategy installed. Resolved once, before the pass
  starts, by `Encryptor.Ecto.Migrator`.
  """
  @type index :: %{
          column: atom(),
          declaration: Encryptor.Ecto.BlindIndex.Declaration.t(),
          params: map()
        }

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
          scope: Encryptor.Ecto.Migrator.Plan.scope(),
          scope_column: atom() | nil,
          from_source: Source.resolved(),
          source_authenticated: boolean(),
          validate: (term() -> term()) | nil,
          index: index() | nil,
          to: module(),
          to_arity: 1 | 3,
          to_params: term(),
          target_header: target_header() | nil,
          mode: Encryptor.Ecto.Migrator.pass_mode(),
          writing_key: String.t() | nil,
          batch_size: pos_integer(),
          sample: pos_integer() | :all,
          on_error: :halt | :continue,
          prefix: String.t() | nil,
          checkpoint: :table | :none,
          checkpoint_table: String.t(),
          only_scopes: [String.t()] | nil,
          except_scopes: [String.t()],
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
    :scope,
    :scope_column,
    :from_source,
    :source_authenticated,
    :validate,
    :index,
    :to,
    :to_arity,
    :to_params,
    :target_header,
    :mode,
    :writing_key,
    :batch_size,
    :sample,
    :on_error,
    :prefix,
    :checkpoint,
    :checkpoint_table,
    :only_scopes,
    :except_scopes,
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
      pass.scope_column,
      cursor,
      pass.batch_size
    )
    |> filter_scopes(pass)
    |> pass.repo.all(query_opts(pass))
  end

  @spec read_sample(t(), pos_integer()) :: [list()]
  defp read_sample(pass, size) do
    pass.source
    |> Keyset.sample_query(
      pass.key,
      pass.source_column,
      pass.target_column,
      pass.scope_column,
      size
    )
    |> filter_scopes(pass)
    |> pass.repo.all(query_opts(pass))
  end

  @spec filter_scopes(Ecto.Query.t(), t()) :: Ecto.Query.t()
  defp filter_scopes(query, %__MODULE__{scope_column: nil}), do: query

  defp filter_scopes(query, pass) do
    Keyset.scope_filter(query, pass.scope_column, pass.only_scopes, pass.except_scopes)
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

  # The fold carries the identities this batch has proven the target reads,
  # which is the whole of the probe's memo: it starts empty at every batch and
  # is dropped with the fold. See the moduledoc's "Two ways to probe".
  @spec rows(t(), Report.t(), [list()]) :: {Report.t(), :ok | :halt}
  defp rows(pass, report, rows) do
    {report, status, _proven} =
      Enum.reduce_while(rows, {report, :ok, MapSet.new()}, fn row, {report, _status, proven} ->
        case row(pass, report, proven, row) do
          {report, :ok, proven} -> {:cont, {report, :ok, proven}}
          {report, :halt, proven} -> {:halt, {report, :halt, proven}}
        end
      end)

    {report, status}
  end

  # -- one row --------------------------------------------------------------

  @spec row(t(), Report.t(), MapSet.t(identity()), list()) ::
          {Report.t(), :ok | :halt, MapSet.t(identity())}
  defp row(_pass, report, proven, [_id, nil, _target | _scope]),
    do: {Report.count(report, :null), :ok, proven}

  defp row(pass, report, proven, [id, source_value, target_value | scope]) do
    scope = row_scope(scope)

    RowScope.with_scope(scope, fn ->
      case probe(pass, proven, target_value) do
        {:already_target, proven} ->
          {Report.count(report, :already_target), :ok, proven}

        {:not_target, proven} ->
          {report, status} = migrate(pass, report, id, source_value, target_value, scope)
          {report, status, proven}
      end
    end)
  end

  # ADR-0002 proposed amendment 2: which of the two migratable classes this
  # field's rows are counted under. A property of the field, so it is the same
  # answer for every row of the pass.
  @spec migratable(t()) :: Report.class()
  defp migratable(%__MODULE__{source_authenticated: false}), do: :migratable_unverified
  defp migratable(_pass), do: :migratable

  @spec row_scope([term()]) :: term()
  defp row_scope([scope]), do: scope
  defp row_scope([]), do: nil

  # Decision 5, both ways: see the moduledoc's "Two ways to probe". A
  # verification and a target this package cannot read a header claim out of
  # take the load attempt; everything else reads the header, and believes it
  # only for an identity this batch has already proven.
  @spec probe(t(), MapSet.t(identity()), binary() | nil) ::
          {:already_target | :not_target, MapSet.t(identity())}
  defp probe(_pass, proven, nil), do: {:not_target, proven}

  defp probe(%__MODULE__{mode: :verify} = pass, proven, bytes),
    do: {load_probe(pass, bytes), proven}

  defp probe(%__MODULE__{target_header: nil} = pass, proven, bytes),
    do: {load_probe(pass, bytes), proven}

  defp probe(%__MODULE__{target_header: header} = pass, proven, bytes) do
    case claimed(header, bytes, pass.writing_key) do
      :no -> {:not_target, proven}
      {:claims, identity} -> against_proof(pass, proven, identity, bytes)
    end
  end

  # An identity a load has already proven this batch is believed; the first
  # row claiming one is loaded, and joins the proof only where that load
  # succeeded. A source row - a different vault, a different key, a re-keyed
  # one - fails here exactly as it fails on a probe that never read a header,
  # which is what keeps an R3 rewrite (ADR-0002's "format, algorithm, library,
  # or encryption context") from silently doing nothing.
  @spec against_proof(t(), MapSet.t(identity()), identity(), binary()) ::
          {:already_target | :not_target, MapSet.t(identity())}
  defp against_proof(pass, proven, identity, bytes) do
    cond do
      MapSet.member?(proven, identity) ->
        {:already_target, proven}

      load_probe(pass, bytes) == :already_target ->
        {:already_target, MapSet.put(proven, identity)}

      true ->
        {:not_target, proven}
    end
  end

  # `describe/1` returns what the writer of the bytes says, so this is a
  # comparison of claims and not a verification of one. A header whose context
  # or algorithm suite differs from the target's belongs to some other
  # declaration - the context-change rewrite's `from:` side, most often - and
  # the row is rewritten, which is the answer a decrypt would also have given.
  # What survives this comparison is not yet an answer: it is a claim to hand
  # to `against_proof/4` under the identity it makes.
  #
  # A rotation's predicate is the second half, and it is applied to the claim
  # rather than folded into the declaration comparison: which key version wrote
  # a row is a fact about the row, while everything `against_declaration/2`
  # compares is a fact about the declaration, and a rotation is a property of
  # the pass rather than of the column.
  @spec claimed(target_header(), binary(), String.t() | nil) :: {:claims, identity()} | :no
  defp claimed(header, bytes, writing_key) do
    case Message.describe(bytes) do
      {:ok, info} -> claimed_by(header, info, writing_key)
      _unreadable -> :no
    end
  rescue
    _exception -> :no
  end

  @spec claimed_by(target_header(), Message.Info.t(), String.t() | nil) ::
          {:claims, identity()} | :no
  defp claimed_by(header, info, writing_key) do
    with {:claims, identity} <- against_declaration(header, info) do
      if written_under?(info, writing_key), do: {:claims, identity}, else: :no
    end
  end

  # Name equality over every encrypted data key the header names, and only
  # where the option asked for it: `nil` is every pass that is not a rotation,
  # and answers `true` without reading anything. The name is a version identity
  # travelling in the clear and a pseudonym rather than a scope identifier
  # (`Encryptor.Message.Info`), so it is a comparison target here and nothing
  # else - a forged one can only have the pass leave a row alone, which is what
  # a header claim can always do.
  #
  # A header naming no keys at all is not the target either. "Every entry
  # matches" is vacuously true of an empty list, and a message of this format
  # carries at least one entry, so the arm is unreachable rather than
  # load-bearing - but a rotation's whole job is that no row in scope still
  # claims another version, and a row claiming nothing has not been shown to
  # claim this one.
  @spec written_under?(Message.Info.t(), String.t() | nil) :: boolean()
  defp written_under?(_info, nil), do: true

  defp written_under?(%{encrypted_data_keys: [_first | _rest] = keys}, writing_key),
    do: Enum.all?(keys, &(&1.key_name == writing_key))

  defp written_under?(_info, _writing_key), do: false

  @spec against_declaration(target_header(), Message.Info.t()) :: {:claims, identity()} | :no
  defp against_declaration(header, info) do
    {scope_ref, context} =
      info.encryption_context
      |> declared_pairs()
      |> Map.pop(Context.scope_ref_key())

    # The `"tenant_ref"` presence comparison is a fast path rather than a guard:
    # ADR-0001 decision 5e forbids a global field on a `:scoped`-profile vault,
    # so a scope-bearing and a global declaration cannot coexist over one
    # vault, and a header that disagreed could only change the answer for a row
    # `against_proof/4`'s load would have accepted anyway. Kept because it
    # settles the common case without a decrypt.
    if context == header.context and is_binary(scope_ref) == header.scope_ref? and
         info.algorithm_suite_id == header.suite do
      {:claims, %{suite: info.algorithm_suite_id, keys: info.encrypted_data_keys}}
    else
      :no
    end
  end

  # What is left of a message's context after the pairs no declaration is
  # allowed to write are removed. `Encryptor.Context` reserves two prefixes,
  # and the engine writes one of them itself: a signing suite puts its public
  # key in the context, so comparing those pairs against a declared context
  # would be comparing something the declaration never composed - and would
  # have the short-circuit silently never fire for a vault configured to sign.
  # The suite is compared as a suite, on the line above, which is where that
  # difference belongs.
  @spec declared_pairs(%{optional(String.t()) => String.t()}) :: %{
          optional(String.t()) => String.t()
        }
  defp declared_pairs(context) do
    Map.reject(context, fn {key, _value} ->
      Enum.any?(Context.reserved_prefixes(), &String.starts_with?(key, &1))
    end)
  end

  # The load attempt's failure is the ordinary case rather than an event: a row
  # that has not been rewritten yet fails it every time. So every failure shape
  # - a raise from a type that raises by design (ADR-0001 decision 6), an
  # `:error` from an `Ecto.Type`, an off-contract return - is the same answer
  # here, and none of them reaches the report.
  @spec load_probe(t(), binary()) :: :already_target | :not_target
  defp load_probe(pass, bytes) do
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
  defp migrate(%__MODULE__{mode: :verify} = pass, report, id, source_value, _target, scope) do
    case load_source(pass, source_value, scope) do
      {:ok, _loaded} -> {Report.count(report, migratable(pass)), :ok}
      {:error, reason} -> fail(pass, report, id, reason)
    end
  end

  defp migrate(pass, report, id, source_value, target_value, scope) do
    with {:ok, loaded} <- load_source(pass, source_value, scope),
         {:ok, bytes} <- write_target(pass, loaded),
         {:ok, set} <- index_set(pass, loaded) do
      swap(pass, report, id, target_value, [{pass.target_column, bytes} | set])
    else
      {:error, reason} -> fail(pass, report, id, reason)
    end
  end

  # The folded index, as the extra column of the swap's `set`: nothing for a
  # field that folds none, so the default path's `UPDATE` is unchanged. There
  # is no `NULL` arm like `put_index/3`'s (ADR-0003 decision 8): a `NULL`
  # source is step 1's and is never loaded, and a loaded `nil` has already met
  # `write_target/2`, which refuses a dump that yields no bytes. A `nil` that
  # a target did dump to bytes reaches the normalizer here and is refused as
  # an index failure, not written. The reason is wrapped with the column so
  # the report attributes the failure to the index rather than to the
  # rewrite, and reduced to a module name so neither the plaintext nor an
  # index value can reach it.
  @spec index_set(t(), term()) :: {:ok, keyword()} | {:error, term()}
  defp index_set(%__MODULE__{index: nil}, _loaded), do: {:ok, []}

  defp index_set(%__MODULE__{index: index}, loaded) do
    {:ok, [{index.column, Value.compute!(index.declaration, loaded, :dump, index.params)}]}
  rescue
    exception -> {:error, {:blind_index, index.column, {:raised, exception.__struct__}}}
  end

  # The read and the host's check are one step: nothing downstream should have
  # to remember to validate, and a value that fails the check is not a value
  # this pass has read successfully.
  @spec load_source(t(), binary(), term()) :: {:ok, term()} | {:error, term()}
  defp load_source(pass, value, scope) do
    with {:ok, loaded} <- read_source(pass, value, scope),
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
  defp read_source(pass, value, scope) do
    Source.load(pass.from_source, value, source_params(pass, scope))
  end

  # ADR-0002 decision 3: the migrator constructs the params it hands both
  # sides, rather than reading them off a schema declaration. What a foreign
  # arity-3 `from:` module makes of them is its own business; the identifying
  # keys are here because a host's own legacy type may well need them, and the
  # scope is here because a per-scope legacy scheme could not read the row
  # without it.
  @spec source_params(t(), term()) :: map()
  defp source_params(pass, scope) do
    %{
      schema: pass.schema,
      field: pass.field,
      table: pass.source,
      column: Atom.to_string(pass.source_column),
      scope: scope
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

  @spec swap(t(), Report.t(), term(), binary() | nil, keyword()) :: {Report.t(), :ok | :halt}
  defp swap(%__MODULE__{mode: :dry_run} = pass, report, _id, _previous, _set),
    do: {Report.count(report, migratable(pass)), :ok}

  defp swap(pass, report, id, previous, set) do
    query = Keyset.swap_query(pass.source, pass.key, id, pass.target_column, previous)

    case pass.repo.update_all(query, [set: set], query_opts(pass)) do
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

  # One row, read after a lost compare-and-swap, and the load attempt is the
  # right probe for it twice over: the application has just written this row,
  # so the decrypt is the thing being asked about, and a single row is not
  # where a per-batch proof pays for itself.
  @spec reprobe(t(), term()) :: :already_target | :not_target
  defp reprobe(pass, id) do
    query = Keyset.row_query(pass.source, pass.key, id, pass.target_column)

    case pass.repo.all(query, query_opts(pass)) do
      [[bytes]] when is_binary(bytes) -> load_probe(pass, bytes)
      _gone_or_null -> :not_target
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
