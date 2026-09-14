# ADR-0002: the migrator - a plan-driven, resumable, compare-and-swap row rewriter

Status: accepted (2026-08-27; the design is unchanged - the assumption
table and open questions carry their acceptance resolutions, and A14 is
reworded per enc-ADR-0005)

## Amendments (2026-08-27; accepted 2026-09-13)

Status: **accepted (2026-09-13)**, by the operator's reading; the decision
text below is unchanged. These fold ADR-0004's extensions to this record into this
record, so that the field spec and the report classification are readable in
one place rather than assembled from two.

The operator's ruling of 2026-08-27 opens with the words that decide this
one:

> accept all recs as written

**1. `field_spec/0` gains `source_authenticated:` and `validate:`.**
ADR-0004 decision 3a lets a plan field declare `source_authenticated: false`
where the legacy cipher is unauthenticated, and decision 3b adds `validate:`,
a host-supplied `(term() -> boolean())` applied to the loaded plaintext
before it is re-encrypted. The declaration is an acknowledgement rather than
a capability flag, and it is not free: a field declaring
`source_authenticated: false` refuses to run in `--mode write` unless
`validate:` is declared alongside it. The spec in "The contract as typespecs"
below reads, as amended:

```elixir
@type field_spec :: [
        from: module(),
        to: module(),
        into: atom() | nil,
        source_authenticated: boolean(),
        validate: (term() -> boolean()) | nil
      ]
```

An AEAD legacy cipher - the common case - declares neither and is unaffected.

**2. `Report.class/0` gains `:migratable_unverified`.** Decision 7's
classification gains a fifth class, reported in place of `:migratable` for a
field declared `source_authenticated: false`: the probe failed and the `from`
load succeeded, but nothing authenticated the bytes it read. `verify` counts
it separately, so an operator's evidence never says "verified" about rows
nothing verified. As amended:

```elixir
@type class ::
        :null
        | :already_target
        | :migratable
        | :migratable_unverified
        | :undecryptable
```

and decision 7's table gains the corresponding row:

| Class | Meaning |
|---|---|
| `:migratable_unverified` | Probe failed, `from` load succeeded, and the source cipher is unauthenticated (ADR-0004 d3) |

A row whose loaded value fails `validate:` is classified `:undecryptable`
and handled by decision 11 exactly as any other failure - there is still no
class that means "skipped silently".

**3. A14 needed no change.** `ece-0rn` carries a conductor addition recording
that A14 should read "needs nothing from the migrator" per enc-ADR-0005 open
question 2. It already does: the reword landed with this record's acceptance,
and both the status line above and the A14 resolution below carry it. This
section records the check rather than a change.

**4. Q6 is answered: keyset ordering covers single-column integer and binary
primary keys, and composite primary keys are documented as unsupported.**
The operator's ruling of 2026-08-27 accepted the written recommendation for
this question as it stood:

> integer/binary PKs day one, composite documented-unsupported until asked
> for.

Decision 6's `where: r.id > ^cursor` / `order_by: r.id` keyset pagination is
therefore defined for a schema whose primary key is a single column of an
integer type or a binary type. Both are a total order every supported adapter
expresses as one `>` comparison on one column, which is exactly what decision
6's query needs, and the binary case covers UUID keys stored as
`:binary_id`. A UUIDv4 key orders correctly
and scatters over the index; that is a cost in read locality, not a
correctness problem, and it does not change what the migrator does.

A schema whose primary key is composite, or a single column of a type with no
total order the query builder can express, is **out of scope for the founding
implementation and is documented as such**. The migrator refuses it with a
clear error naming the schema and its primary key rather than paging over it
under a guess. No `order_by:` escape hatch is added: the escape hatch was the
other candidate ADR-0004 Q3 named, and adding it now would buy an untested
generality at the cost of a plan option every host reads and almost none
needs. "Until asked for" is the operative half of the ruling - a real host
arriving with a composite-key table is what reopens this, and reopening it is
additive to the plan surface rather than a change to it.

Consequence for the implementer (`ece-b25` builds directly on this): keyset
pagination orders on integer and binary primary keys day one; composite and
non-orderable primary keys are documented as unsupported until a real request
arrives, and are refused with a clear error rather than handled partially.

**5. Q4 is proposed answered: `gen.migration` ships, because decision 9's
refusal is about *executing* DDL and not about *authoring* it.** Recorded on
`ece-l6t`. Unlike amendment 4 above, this one carries no operator ruling
behind it: it is a recommendation drafted for the operator's read, and
acceptance is theirs.

Q4 asks whether shipping a migration generator is consistent with "no DDL".
The recommendation is that it is, and that the apparent tension comes from
reading decision 9 as a refusal to have opinions about tables rather than a
refusal to hold authority over them. Decision 9's own seam sentence is the
test: *if an operation would still be needed by a host that stores its
ciphertext somewhere other than Ecto, it is not this package's.* A host that
does not store ciphertext in Ecto needs no checkpoint table at all, so the
checkpoint is on this side of the seam by that record's own rule. What
decision 9 protects is the host's control over schema change - its review,
its rollback, its deploy coupling - and a file the host reads in a diff,
commits, and runs with its own `mix ecto.migrate` preserves every one of
those. The package opens no connection and runs no DDL, at runtime or from a
task, which is what the refusal actually says.

The alternative Q4 names, progress to a file or to stdout only, is rejected
as the *default* for the reason Q4 itself gives and for one it does not. The
reason it gives: a container has no durable filesystem, so the cursor a
six-hour pass earned dies with the pod. The reason it does not: the
checkpoint written by the same transaction as the batch it describes is
consistent with that batch by construction, and a file written beside a
database transaction is not - a crash between the commit and the write leaves
a cursor that disagrees with the rows. Decision 5 means that disagreement
costs a re-scan rather than correctness, which is exactly why this is a
recommendation about cost and not about safety.

Accepting this answer would add three things the accepted text leaves
unspecified, and all three exist because "this package effectively owns a
table's schema" is a real cost that is better paid explicitly than left
implicit:

- **The table is named, and the name is an option.** The generated migration
  creates `encryptor_ecto_migration_checkpoints` by default, and both `run/2`
  and the generator accept `checkpoint_table:` for a host whose naming
  convention or schema layout differs. Its columns are decision 6's tuple, one
  row per field per prefix: `plan`, `schema`, `field`, `prefix`, `last_id`,
  the counts, `started_at`, `updated_at`, with a unique index over
  `{plan, schema, field, prefix}`. `last_id` stores the rendered primary key
  as text rather than a typed column, because amendment 4 admits both integer
  and binary primary keys and one checkpoint table serves both.
- **A missing or stale checkpoint table is a refusal, never a creation.**
  `run/2` preflights the table and, if it is absent, halts naming
  `mix encryptor.ecto.gen.migration` rather than issuing the `CREATE TABLE`
  itself. This is the line decision 9 draws, drawn at the one place where
  crossing it would be convenient.
- **`checkpoint: :none` keeps the rejected alternative available as a
  documented degraded mode.** A host that will not add the table runs the pass
  with no checkpoint at all and reports progress to stdout. Decision 5 makes
  that correct rather than merely tolerable: without a checkpoint, `resume:
  true` is meaningless and every run is a full scan, which is slow and never
  wrong. Naming the mode is what turns "we thought about a file and decided
  against it" into a choice the host can make.

Consequence for the implementer (`ece-5qb` ships `gen.migration` either way,
and `ece-b25` builds the preflight): the generator emits the named table, the
engine refuses rather than creates, and `checkpoint: :none` is an `opts()`
member alongside `resume:`.

**6. Q5 is proposed answered: the plan stays single-repo and prefix-free,
visiting prefixes is a run option rather than a plan option, and the
checkpoint key gains the prefix.** Recorded on `ece-l6t`. This one likewise
carries no operator ruling; it is a recommendation for the operator's read.

*The multi-repo half is already answered and is restated only so that
`ece-vqe` does not reopen it.* Decision 12 says a plan names one repo and a
host with several writes several plans. Nothing here changes that: the plan's
`repo:` stays singular and no `repos:` list is added. A sharded host is the
same shape - `Repo.put_dynamic_repo/1` before `run/2`, per decision 12 - and
it needs no shard component in the checkpoint key, because the checkpoint
lives in whichever repo is current, so each shard already keeps its own.

*The prefix half is the open part, and the recommendation is the middle of
Q5's three candidates.* A `prefix:` option on `run/2` (and `--prefix` on the
task), singular, defaulting to the repo's own default prefix. Not a
`prefixes:` list in the plan module, and not "nowhere yet".

Not in the plan, because ADR-0001 decision 4 supplies the argument in its own
words while excluding the prefix from the encryption context: a prefix is *a
deployment-time placement decision and can differ between environments for the
same logical table*. Decision 2's case for the plan being code is that its
contents are facts about the schema, reviewed in a diff and versioned with the
schema they describe. A prefix list is not such a fact, and baking one in
means either a plan module that differs per environment or one that carries
every environment's list - both of which put a deployment fact through code
review as though it were a schema fact.

Not "nowhere yet", because "nowhere yet" is not free, and this is the finding
that decides the question. Decision 6 keys the checkpoint on `{plan, schema,
field, last_id, ...}`, which carries no prefix. A caller looping `run/2` over
prefixes today - the thing "nowhere yet" tells them to do - has every prefix
sharing one checkpoint row, so the second prefix resumes at the first's cursor
and *silently skips every row below it*. Decision 5's probe-first idempotence
does not cover this: probe-first makes re-visiting a row safe, and this is a
row never visited. So the prefix has to reach the checkpoint key whether or
not the option exists, and once it is in the key the option is the honest way
to put it there.

What is deliberately not added: any enumeration of prefixes. The package ships
no "all prefixes" mode and reads no database catalog to find them. A host
knows its own prefix list, catalog introspection is closer to the schema
authority decision 9 refuses than anything else in this record, and a loop the
host writes is three lines it can see. Because the ciphertext is portable
across prefixes (ADR-0001 decision 4), that loop needs no per-prefix
configuration of any kind - the same plan, the same types, one option
changing.

Consequence for the implementers: `ece-vqe` adds no prefix construct to the
plan DSL and keeps `repo:` singular; `ece-b25` puts `prefix` in the checkpoint
key and in its unique index; `ece-5qb` adds `--prefix` to the `migrate` and
`verify` grammars.

**Amendments 5 and 6 together, rendered against "The contract as typespecs"
below.** Three additions, no removals, and no change to `Plan.t()` - the plan
struct keeps its single `repo:` and gains nothing:

```elixir
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

@spec verify(plan :: module(), [sample: pos_integer() | :all, prefix: String.t() | nil]) ::
        {:ok, Report.t()} | {:error, Report.t()}
```

and `Report.t()`'s `cursors` key widens from `%{{module(), atom()} => term()}`
to `%{{module(), atom(), String.t() | nil} => term()}`, which is the in-memory
face of the same prefix component the checkpoint row gains. `checkpoint:
:table` is the default and `checkpoint: :none` with `resume: true` is an
argument error, for the reason ADR-0004's amended grammar gives: resuming from
a checkpoint that was never written is a request with no meaning.

## Context

ADR-0001 makes a schema field encrypted by naming a type module, and says
plainly that the bytes in the column are upstream's format, stored verbatim
(decision 11). It also says that any change of format, key, or context is "a
data migration (the ece-56a record), not a type-level compatibility shim". This
is that record.

`cloak_ecto` has the ecosystem's reference answer: `mix cloak.migrate`, a
batched pass that loads every row of a configured schema through the old cipher
and writes it back through the new one. It is the right idea and the shape
hosts already know. It is also the shape of a tool written for a library whose
only variable was the cipher. This package has more variables - a per-row
encryption context, a per-tenant key hierarchy, and a two-level envelope
upstream - and the interesting design work is in deciding which of those
variables this tool owns and which it must refuse.

**Four operations look like "migration" and only two of them are row
rewrites.**

| | Operation | Rows touched | Owner |
|---|---|---|---|
| R1 | Rotate the key-encrypting key; re-wrap the wrapped tenant keys | none | `encryptor` (enc-53a) |
| R2 | Rotate a tenant's data key | every ciphertext for that tenant | this record |
| R3 | Change format, algorithm, library, or encryption context | every ciphertext in scope | this record |
| R4 | Crypto-shred a tenant | none; its ciphertexts become permanently unreadable | `encryptor` (enc-53a) |

R1 is the cheap path the envelope design buys (enc-2u6): the payloads are
encrypted under a data key, the data key is wrapped, and rotating the wrapping
key rewrites a handful of wrapped-key records and no user data at all. It is
enormously tempting to put a `mix` task for it here, because here is where the
`Repo` is. That temptation is the thing this record refuses: R1 touches only
the key store, and the key store is `encryptor`'s. A host that can re-wrap its
keys from an Ecto-flavoured task in this package would be a host whose key
lifecycle is split across two packages' documentation, and split key-lifecycle
documentation is how a shred gets half-performed.

**The context problem inverts at migration time.** ADR-0001 decision 5 resolves
the tenant from a process-scoped store set at the edge of a request, precisely
because the request is the only place that knows it. A migrator has no request.
It has a table, and somewhere in that table is a column that says which tenant
each row belongs to. Reaching for the process scope here - setting it per row
from the very column the migrator just read - would work, and it would be the
wrong channel: an ambient mechanism used to carry a value the caller is holding
in its hand. Worse, the same ambient scope is what the *host's* application code
uses, so a migrator running in a process that also serves anything else would be
mutating shared state.

**A migrator that cannot run against live traffic is not a migrator.** The
tables in question are the ones with the sensitive columns, which are the ones
the application writes to constantly. A pass that requires downtime proportional
to row count is a pass that does not get run, and a rotation that does not get
run is a compliance artifact rather than a control. Read-modify-write over a
live table has an obvious hazard - the application writes the row between the
read and the write, and the migrator clobbers it with a re-encryption of stale
plaintext - and that hazard has an equally obvious answer if the tool is willing
to be built around it.

## Decision

**1. The library function is the interface; the mix task is a wrapper.**
`Encryptor.Ecto.Migrator.run/2` and `verify/2` are the contract. `mix
encryptor.ecto.migrate` and `mix encryptor.ecto.verify` are thin argument
parsers over them.

This is not a stylistic preference. Production hosts run releases, and a release
has no Mix. A rotation that can only be driven by a mix task is a rotation that
can only be performed from a developer's laptop against production credentials,
which is the opposite of the control it is supposed to be. Every capability in
this record is reachable from `Encryptor.Ecto.Migrator`, so a host can put it
behind a release command, an Oban job, an admin action, or an approval workflow
of its own.

**2. The unit of work is a migration plan module, checked into the host.**
Not application config, not task flags:

```elixir
defmodule MyApp.Encryption.CloakMigration do
  use Encryptor.Ecto.Migration, repo: MyApp.Repo

  rewrite MyApp.Accounts.Customer do
    tenant_from :account_id

    field :tax_id, from: MyApp.Cloak.Encrypted.Binary, to: MyApp.Encrypted.Binary
    field :notes, from: MyApp.Cloak.Encrypted.String, to: MyApp.Encrypted.String
  end

  rewrite MyApp.Reference.Code do
    tenant :none
    field :value, from: MyApp.Cloak.Encrypted.Binary, to: MyApp.Encrypted.Binary
  end
end
```

A plan is code because everything in it is code: the `from` and `to` sides are
type modules, and which fields are encrypted is exactly the kind of fact that
should be reviewed in a diff, versioned with the schema it describes, and
deleted in a named commit when the migration is finished. Config would make the
most consequential operation this package performs invisible to code review.

The macros validate at compile time: every named field exists on the schema,
every `from`/`to` module exports the `Ecto.ParameterizedType` (or `Ecto.Type`)
callbacks, and `tenant_from` names a real column. A plan that would fail on row
one fails at `mix compile` instead.

**3. The migrator works below the schema layer, and supplies context
explicitly.** It does not build changesets and does not call `Repo.update/2`.
For each row it reads the primary key, the tenant column, and the raw ciphertext
columns; it calls the `from` type's `load/3` and the `to` type's `dump/3`
*directly*, with params it constructs, and writes the resulting bytes with
`update_all` over the ciphertext columns only.

Three properties follow, and all three are the reason:

- **The tenant is passed, not ambient.** The migrator installs a per-row tenant
  resolver in the params it constructs, which is ADR-0001 decision 5f (the
  `Encryptor.Ecto.TenantContext` escape hatch) used exactly as intended. It
  never calls `Encryptor.Ecto.Tenant.put/1`, so it cannot corrupt the scope of
  a process that is doing anything else, and `MissingTenantError` (5c) is
  structurally unreachable inside a migration.
- **`from` and `to` may be the same module with different params.** A field
  moving from `tenant: :none` to `tenant: :scope`, or gaining a `:context`
  pair, is a context change and therefore a full rewrite even though no type
  module changed. Because the migrator constructs both sides' params itself,
  this is expressible; a migrator built on schema declarations could only ever
  express the type-module case.
- **No host side effects.** `updated_at` is not touched, `lock_version` is not
  incremented, no `Ecto` callbacks fire, no host audit trail records a
  million-row phantom update. Re-encryption is not a business event and should
  not look like one.

**4. Writes are compare-and-swap, so the pass is safe against live traffic.**
The update is conditional on the ciphertext column still holding the exact bytes
the migrator read:

```elixir
from(r in schema,
  where: r.id == ^id and r.tax_id == ^bytes_we_read,
  update: [set: [tax_id: ^new_bytes]]
)
```

Zero rows affected means the application wrote that row while the migrator was
working on it. That is not an error: the application wrote it through the `to`
type, so the row is *already* in the target state. The migrator re-probes the
row (decision 5), counts it as concurrently-migrated, and moves on. Rows are
therefore never clobbered with stale plaintext, and no table-level or row-level
lock is held across the decrypt/encrypt work.

This is the decision that makes everything else in this record affordable: with
compare-and-swap the pass needs no downtime, no maintenance window, and no
coordination with deploys beyond the both-libraries window of decision 8.

**5. Correctness comes from probing; checkpoints only make it fast.** Before
rewriting a row the migrator probes it: attempt `to.load/3`. If it succeeds, the
row is already in the target state and is skipped. Only if the target load fails
does the migrator attempt `from.load/3` and rewrite.

Probe-first makes the whole pass idempotent by construction. Running it twice,
resuming it from the wrong cursor, running it concurrently with the application
writing new rows through the new types, or interrupting it with SIGKILL midway
through a batch all converge on the same end state. The checkpoint (decision 6)
is then purely a performance record - losing it costs a re-scan, never
correctness. A design whose correctness depended on the checkpoint would be a
design that must get crash semantics exactly right on the one code path nobody
tests.

The probe costs one decrypt attempt per already-migrated row. Where upstream can
report a message's key version without decrypting (assumption A9), the probe
short-circuits to a header inspection; where it cannot, the cost is real and is
the price of the property.

**6. Batching is keyset, resume is a cursor, and the checkpoint is the host's
table.** Rows are visited in primary-key order using keyset pagination
(`where: r.id > ^cursor`, `order_by: r.id`, `limit: ^batch_size`), never
`OFFSET`, which degrades quadratically and skips rows when the set shifts under
it. Default batch size 500; each batch is one transaction; there is no
transaction spanning batches.

After each batch the migrator records `{plan, schema, field, last_id, counts,
started_at, updated_at}` in a checkpoint table. That table is created by an
**Ecto migration the host writes**, from a generator this package ships
(`mix encryptor.ecto.gen.migration`). This package issues no DDL of its own,
ever - see decision 9.

`run/2` with `resume: true` starts after the recorded cursor. `resume: false`
starts from the beginning, which - because of decision 5 - is always a legal
thing to do.

**7. There is no default mode: exactly one of `:dry_run` or `:write`.** The task
refuses to run without one, and the library function's option is required.

A dry run performs every read, every probe, every decrypt and every encrypt, and
discards the write. It is therefore an exact rehearsal of the work, including
which rows fail to decrypt and how long it takes, and it reports a
classification:

| Class | Meaning |
|---|---|
| `:null` | Column is `NULL`; nothing to do |
| `:already_target` | Probe succeeded; row is in the target state |
| `:migratable` | Probe failed, `from` load succeeded |
| `:undecryptable` | Neither side loads; needs an operator decision |

Making dry-run the default would train operators to add a flag they stop
reading. Making write the default would put an irreversible pass one typo away.
Requiring the choice costs one word and removes both.

**8. Both libraries in the tree, and no dependency on either.** The
cloak-to-encryptor migration runs with `cloak_ecto` still in `mix.exs`. The plan
names the host's cloak type modules as `from:`; this package calls them through
the `Ecto.Type` behaviour and has **no dependency on `cloak_ecto`, optional or
otherwise**. Anything satisfying the callbacks works, which also covers a host
migrating off a hand-rolled type.

The sequence a host follows:

1. Deploy with both libraries present and the schema fields still naming the
   *cloak* type modules. Nothing has changed yet.
2. No column is added and no DDL runs: both formats are `:binary` bytes in the
   column that already exists. This is why the migration is data-only.
3. Run the migrator in dry-run, then write mode, against live traffic. During
   the pass the table holds a mix of both formats, which reads correctly only
   through a type that can load both.
4. **The mixed window needs a reader that tolerates both.** For the duration,
   the host's type module is a `from`-aware shim - a `use Encryptor.Ecto.Binary`
   module configured with `legacy: MyApp.Cloak.Encrypted.Binary`, which loads
   through the legacy type when the primary load fails and always dumps through
   the new one. This is a migration affordance with an expiry date, documented
   as such, and it is the *only* concession this package makes to
   backward-compatible loading. It is an option on the type (an amendment this
   record proposes to ADR-0001 decision 3's closed option set, listed in the
   open questions as Q1).
5. Verify (decision 10). Drop `legacy:`, drop `cloak_ecto`, delete the plan
   module.

`Encryptor.Ecto.Migrator.Source.Plaintext` covers the other adoption path: a
column that was never encrypted. That case is **not** a data-only migration -
plaintext lives in a `:string`/`:text` column and ciphertext must live in
`:binary` - so it is an expand/backfill/contract dance across two columns and
two deploys. The migrator does the backfill leg (`into:` names a different
target column); the DDL and the cutover are the host's Ecto migrations, in a
documented runbook.

**9. This package issues no DDL, and re-wrap does not live here.** Two refusals,
one principle: the migrator's authority stops at the ciphertext columns of the
host's own tables.

- No `CREATE TABLE`, no `ALTER COLUMN`, no index changes, at runtime or from a
  task. Schema change is the host's migration story and has its own review,
  rollback, and deploy coupling. The checkpoint table arrives as generated
  migration source the host reads and runs (decision 6).
- No re-wrap, no key creation, no shred (R1 and R4 above). Those touch the key
  store, which is `encryptor`'s (enc-53a, enc-2u6). This package's task list
  contains no verb that operates on a key.

The seam is legible: **if an operation would still be needed by a host that
stores its ciphertext somewhere other than Ecto, it is not this package's.**

**10. Verification is a first-class pass, and it has a SQL-only half.**
`Encryptor.Ecto.Verifier.run/2` (`mix encryptor.ecto.verify`) is read-only,
takes the same plan, and produces the decision-7 classification over the whole
scope or a sample (`sample: 1000`). It exits non-zero if any row is not
`:already_target` or `:null`. It is the acceptance test for a rotation, and it
is what a host runs on a schedule to detect drift.

Beneath it, and cheaper, is a set of documented SQL queries that need neither
the application nor any key material, relying on the message header being
byte-inspectable (assumption A8):

```sql
-- Format census. Rows not yet migrated still carry the legacy prefix.
SELECT substring(tax_id from 1 for 4) AS header, count(*)
FROM customers WHERE tax_id IS NOT NULL GROUP BY 1 ORDER BY 2 DESC;

-- Rotation progress for one tenant, by key version in the header.
SELECT count(*) FILTER (WHERE substring(notes from 1 for 4) = :current_hdr) AS done,
       count(*) FILTER (WHERE notes IS NOT NULL) AS total
FROM customers WHERE account_id = :account_id;

-- Nothing became NULL and nothing became empty. Run before and compare.
SELECT count(*) AS rows,
       count(tax_id) AS non_null,
       count(*) FILTER (WHERE octet_length(tax_id) = 0) AS empty
FROM customers;
```

These exist because an operator watching a six-hour pass should not have to run
the application to know where it is, and because a DBA reviewing the change
should be able to confirm the outcome without being handed a key.

**11. Failures are loud, and the default is to stop.** A row that is neither
target-readable nor source-readable halts the pass, reporting the primary key,
the table, the column, and the upstream reason. `on_error: :continue` records
the failure (bounded list plus a count, in the checkpoint row), finishes the
pass, and exits non-zero. There is no mode that skips a row silently, and no
mode that exits zero with failures recorded.

The expected legitimate case for `:continue` is a crypto-shredded tenant (R4):
its rows are permanently undecryptable by design. The plan expresses that with
a tenant filter (`only_tenants:` / `except_tenants:`) rather than by tolerating
errors, so the shredded rows are never visited and the pass still exits zero.
`:continue` remains for the case where the operator does not yet know why a row
will not open - and finding that out is the point of the run.

No exception, log line, or report from the migrator contains plaintext,
ciphertext bytes, or key material. ADR-0001 decision 6's prohibition applies
here verbatim, and a migrator is where it is most likely to be violated: this is
the one component that holds every plaintext in the database in its hands, one
batch at a time.

**12. One process, one repo, deliberately.** No parallel workers, no partitioned
ranges, no multi-repo fan-out in the founding design. A plan names one repo; a
host with several writes several plans. Concurrency is a real want for large
tables and is deferred, not designed here: keyset ranges partition cleanly, so
adding it later is additive and needs no change to the plan format or the
checkpoint schema. `Repo.put_dynamic_repo/1` before `run/2` covers the dynamic
repo case today.

## Upstream API assumptions

Extending ADR-0001's A1-A7 in the same spirit: **each is a review item for
acceptance**, not a settled fact. A1-A7 continue to hold and are not restated.

| # | Assumed | Used by |
|---|---|---|
| A8 | The vault message begins with a stable, byte-inspectable header identifying format version and key version, so a row's state can be classified in SQL without decrypting | 10 |
| A9 | That header's key version is readable through a vault function without performing a decrypt (`Encryptor.Vault.info/1` or equivalent) | 5, 10 |
| A10 | Encrypt always uses the tenant's *current* key version; the migrator never selects a key version, it only causes a re-encrypt | 3, R2 |
| A11 | Decrypt resolves the writing key version from the message, so old and new versions coexist in one table for the duration of a pass | 4, 8 |
| A12 | Tenant key rotation produces a new current version while prior versions stay decryptable until an explicit shred - rotation and shred are separate operations with a window between them | R2, 11 |
| A13 | A shredded tenant's decrypt failure is distinguishable from a corrupt-message failure, so verification can classify rather than guess | 10, 11 |
| A14 | Re-wrap of wrapped tenant keys (R1) is offered by `encryptor` and needs nothing from the migrator | 9 |

*Resolved at acceptance (2026-08-27), verdicts from enc-ADR-0004/0005:*

- *A9 is satisfied: enc-ADR-0004 decision 12's `describe/1` returns the
  stored context and every EDK's `{provider_id, key_name}` (which carries
  the key version) keylessly, so the probe short-circuit and the census
  are real. Its output is unauthenticated and is never an authorization
  input. A8's byte-stable header remains a stated engine-format fact.*
- *A10 and A11 hold. A12 holds exactly as stated: the window exists, is
  unbounded above, has a non-zero lower bound (rewrite + verify + cache
  drainage), and only an explicit shred closes it (enc-ADR-0005 d2).*
- *A13 holds for whole-tenant shreds (`{:unknown_key, _}` at resolution)
  and not for a single retired version (`:decrypt_failed`); decision 11's
  tenant-filter shape is the one that works, so no change here.*
- *A14 as originally written ("needs nothing from the Ecto layer") was one
  notch too broad and is reworded above: R1/R4 need a narrow key-store API
  on the store-backed provider (enumerate/update/delete wrappings), outside
  the migrator's plan and task surface. Decision 9's refusal survives
  intact for the migrator.*

A12 is the load-bearing one. If rotation and shred were a single operation, or
if a rotated-away version stopped decrypting immediately, then R2 would require
a stop-the-world rewrite and every decision in this record about running against
live traffic would be void.

## The contract as typespecs

```elixir
defmodule Encryptor.Ecto.Migration do
  @moduledoc "Compile-time DSL for a migration plan."

  @type field_spec :: [from: module(), to: module(), into: atom() | nil]

  @callback __plan__() :: Encryptor.Ecto.Migrator.Plan.t()
end

defmodule Encryptor.Ecto.Migrator.Plan do
  @type rewrite :: %{
          schema: module(),
          tenant: {:column, atom()} | :none | module(),
          fields: [{atom(), Encryptor.Ecto.Migration.field_spec()}]
        }

  @type t :: %__MODULE__{repo: module(), rewrites: [rewrite()]}
end

defmodule Encryptor.Ecto.Migrator do
  @type mode :: :dry_run | :write

  @type opts :: [
          mode: mode(),
          batch_size: pos_integer(),
          resume: boolean(),
          on_error: :halt | :continue,
          only_tenants: [String.t()] | nil,
          except_tenants: [String.t()],
          only: [{module(), [atom()]}] | nil,
          progress: (Report.t() -> any())
        ]

  @spec run(plan :: module(), opts()) :: {:ok, Report.t()} | {:error, Report.t()}
  @spec verify(plan :: module(), [sample: pos_integer() | :all]) ::
          {:ok, Report.t()} | {:error, Report.t()}
end

defmodule Encryptor.Ecto.Migrator.Report do
  @type class :: :null | :already_target | :migratable | :undecryptable
  @type failure :: %{schema: module(), field: atom(), id: term(), reason: term()}

  @type t :: %__MODULE__{
          mode: Encryptor.Ecto.Migrator.mode(),
          counts: %{class() => non_neg_integer()},
          concurrent: non_neg_integer(),
          failures: [failure()],
          failure_count: non_neg_integer(),
          cursors: %{{module(), atom()} => term()},
          started_at: DateTime.t(),
          finished_at: DateTime.t() | nil
        }
end

defmodule Encryptor.Ecto.Migrator.Source do
  @moduledoc "How the migrator reads the pre-migration value of a column."

  @callback load(binary(), params :: map()) :: {:ok, term()} | {:error, term()}
end
```

`Report.t()` is returned on both arms so a failing run still reports everything
it did before failing.

## Worked example: cloak to encryptor, live, in a multi-tenant host app

The host from ADR-0001's worked example, mid-migration. Both libraries are in
the tree and the type modules load either format:

```elixir
defmodule MyApp.Encrypted.Binary do
  use Encryptor.Ecto.Binary,
    vault: MyApp.Vault,
    legacy: MyApp.Cloak.Encrypted.Binary
end
```

The plan, deleted in a named commit once the pass is verified:

```elixir
defmodule MyApp.Encryption.CloakMigration do
  use Encryptor.Ecto.Migration, repo: MyApp.Repo

  rewrite MyApp.Accounts.Customer do
    tenant_from :account_id
    field :tax_id, from: MyApp.Cloak.Encrypted.Binary, to: MyApp.Encrypted.Binary
    field :notes, from: MyApp.Cloak.Encrypted.String, to: MyApp.Encrypted.String
    field :profile, from: MyApp.Cloak.Encrypted.Map, to: MyApp.Encrypted.Map
  end
end
```

Rehearse, then run, from a release:

```
$ bin/my_app eval 'MyApp.Encryption.CloakMigration |> Encryptor.Ecto.Migrator.run(mode: :dry_run)'
customers.tax_id    null 1,204  already_target 0  migratable 812,447  undecryptable 0
customers.notes     null 512    already_target 0  migratable 813,139  undecryptable 0
customers.profile   null 88,301 already_target 0  migratable 725,350  undecryptable 0
dry run: no rows written

$ bin/my_app eval 'MyApp.Encryption.CloakMigration |> Encryptor.Ecto.Migrator.run(mode: :write)'
...
customers.tax_id    written 812,447  concurrent 19  failures 0   cursor 913,388
```

Nineteen rows were written by the application between the migrator's read and
its write. Each was re-probed, found already in the target state (the
application writes through the new type), and counted - not clobbered, not
retried into a lost update.

A single tenant's data-key rotation (R2), months later, is the same tool with a
filter and `from`/`to` naming the same module:

```elixir
Encryptor.Ecto.Migrator.run(MyApp.Encryption.Rotate,
  mode: :write,
  only_tenants: ["acct_A"]
)
```

This paragraph is refined by the amendment at the foot of this file
(2026-09-13): the invocation above is the rotation pass's shape, and it
rewrites nothing until it also carries `writing_key:`.

And the acceptance check:

```
$ bin/my_app eval 'Encryptor.Ecto.Migrator.verify(MyApp.Encryption.CloakMigration, sample: :all)'
customers.tax_id    already_target 812,447  null 1,204  other 0
ok
```

## Open questions

Recorded because they are not this record's to settle.

**Q1. The `legacy:` option amends ADR-0001's closed option set.** Decision 8
needs the target type to load the source format during the mixed window, which
means a fourth option on `use Encryptor.Ecto.Binary` that ADR-0001 decision 3
does not list. It is narrow (load-only, never dump) and self-expiring, but the
closed option set was a deliberate decision there and this record does not amend
a sibling record. Either ADR-0001 gains the option at acceptance, or this record
loses decision 8 step 4 and the migration needs a stop-the-world window. Owner:
ADR-0001, at acceptance.

*Resolved at acceptance (2026-08-27): granted. ADR-0001's acceptance
amendment 4 adds `legacy:` as a load-only, self-expiring option.*

**Q2. Whether A9 (key version without decrypt) actually exists.** If upstream
cannot report a message's key version without decrypting it, the probe in
decision 5 costs a full decrypt on every already-migrated row, and the SQL
census in decision 10 becomes guesswork over opaque bytes. The design still
works - probe-first is still correct - but a resumed pass over a mostly-migrated
table gets expensive, and the checkpoint stops being merely an optimization in
practice. Owner: enc-14p (the vault layer).

*Resolved at acceptance (2026-08-27): it exists - enc-ADR-0004 decision 12's
`describe/1`, keyless and unauthenticated. See the A9 resolution above.*

**Q3. Where the wrapped-key store lives, and whether R1 truly needs nothing
here.** Decision 9 asserts A14 on the strength of the envelope being upstream's.
If the wrapped per-tenant keys turn out to live in a host-owned Ecto table, then
re-wrap is an Ecto operation after all and the seam in decision 9 is drawn in
the wrong place. Owner: enc-2u6 / enc-53a.

*Resolved at acceptance (2026-08-27): the store is an Ecto table in this
package, and the seam holds one notch narrower than drawn - R1/R4 get a
narrow key-store API on the store-backed provider, outside the migrator's
plan and task surface (enc-ADR-0005's answer; A14 reworded accordingly).*

**Q4. Whether shipping a migration *generator* is consistent with "no DDL".**
Decision 6 needs a checkpoint table and decision 9 forbids this package from
creating one, so the compromise is generated migration source the host reviews
and runs. That is the conventional Elixir answer (`oban`, `ecto_sql` itself),
but it does mean this package effectively owns a table's schema while
disclaiming DDL. The alternative - progress to a file or to stdout only - keeps
the disclaimer clean and makes resume unreliable in a container. Not settled.

*Answered 2026-08-27 (`ece-l6t`), recorded as proposed amendment 5 above -
status proposed, and unlike amendment 4 this one carries no operator ruling
behind it, so acceptance is entirely the operator's. Recommendation: the
generator is consistent with decision 9, because that refusal is about
executing DDL and holding schema authority, not about authoring a file the
host reviews and runs. Accepting it names the table
(`encryptor_ecto_migration_checkpoints`, overridable), makes a missing table a
refusal that points at the generator rather than a `CREATE TABLE`, and keeps
Q4's alternative alive as an explicit `checkpoint: :none` degraded mode that
decision 5 makes correct.*

**Q5. Multi-repo, per-tenant prefix, and sharded hosts.** A plan names one repo
and no prefix. ADR-0001 decision 4 deliberately excludes the prefix from the
encryption context, which means ciphertext is portable across prefixes and the
migrator only needs to *visit* every prefix, not vary its context per prefix.
Whether that visiting belongs in the plan (a `prefixes:` list), in the caller (a
loop over `run/2`), or nowhere yet is open. Owner: this repo, before
implementation.

*Answered 2026-08-27 (`ece-l6t`), recorded as proposed amendment 6 above -
status proposed, no operator ruling behind it, acceptance is the operator's.
Recommendation: the middle candidate. A `prefix:` run option and a `--prefix`
flag, not a `prefixes:` list in the plan, because ADR-0001 decision 4 calls a
prefix a deployment-time placement decision and decision 2's case for the plan
being code is that its contents are schema facts. Not "nowhere yet" either:
decision 6's checkpoint key carries no prefix, so a caller looping `run/2`
over prefixes today has the second prefix resume at the first's cursor and
silently skip rows - decision 5's idempotence covers a row re-visited, not a
row never visited. The multi-repo and sharded halves are decision 12's already
and are unchanged. No prefix enumeration is shipped.*

**Q6. Ordering guarantees for non-integer and composite primary keys.** Keyset
pagination needs a total order on the primary key. UUIDv4 keys order fine but
scatter over the index; composite keys need tuple comparison the query builder
does not express uniformly across adapters. The founding implementation may
restrict itself to single-column primary keys and say so. Owner: this repo,
before implementation.

*Answered 2026-08-27 (ece-4ib), recorded as proposed amendment 4 above: the
operator accepted "integer/binary PKs day one, composite
documented-unsupported until asked for". Single-column integer and binary
primary keys are ordered day one; composite and otherwise non-orderable
primary keys are refused with a clear error and documented as unsupported
until a real request arrives. No `order_by:` escape hatch.*

## Consequences

**Rotation stops being a project.** The expensive rotation (R2) and the cheap
one (R1) are separated, named, and owned, and the cheap one - which is the one a
host actually performs on a schedule - never touches this package at all. A
host that rotates its key-encrypting key monthly and its tenant data keys
approximately never is a host with a working control rather than a documented
intention.

**The pass is safe against live traffic and therefore gets run.** Compare-and-
swap plus probe-first idempotence means no window, no lock, no coordination, and
no fear of interrupting it. The cost is one extra decrypt attempt per
already-migrated row and a `WHERE` clause on the ciphertext column, both of
which are cheap enough to be uninteresting.

**The migrator holds every plaintext in the database, one batch at a time.**
This is the most sensitive component in either package: it is the one process
that decrypts everything, and it is typically run by an operator against
production from a shell. The prohibitions in decision 11 are load-bearing, and
so is the fact that it runs from a release command rather than a laptop's `mix`.
Any future logging, telemetry, or progress-reporting addition to this component
is a security review, not a feature.

**The plan module is code that must be deleted.** A finished migration leaves a
module naming the old type modules and a dependency on `cloak_ecto` in
`mix.exs`. Both linger in real projects. The documentation makes deletion the
final numbered step of the runbook, and `verify` exiting zero is the signal that
the step is due - but this record acknowledges that nothing enforces it.

**Verification is available to people without keys.** The SQL half of decision
10 lets a DBA or an auditor confirm the outcome of a rotation from the database
alone. That is a deliberate reversal of the usual position, where the only
evidence of an encryption change is the application's own claim about it.

**Concurrency and the plaintext-adoption DDL are deferred, not decided.**
Decision 12 leaves parallelism additive; decision 8's `Source.Plaintext` leg
leaves the expand/contract sequence to a documented runbook. Both are known
gaps, both are compatible with everything above, and neither blocks the founding
implementation.

## Note (2026-09-13): the probe short-circuit is a rewrite-mode decision; a verification keeps the load

Decision 5 writes the probe as a load attempt and then says, without
qualification, that "where upstream can report a message's key version without
decrypting (assumption A9), the probe short-circuits to a header inspection".
Decision 10 makes `Encryptor.Ecto.Verifier.run/2` the acceptance test for a
rotation, and its whole value is that it opens the bytes rather than believing
a header - the SQL half beneath it is already the keyless answer. Read
literally, the two sentences collide: a verification that short-circuited to a
header inspection would be the census with a slower loop around it.

**The short-circuit belongs to the rewrite modes, and a verification takes the
load attempt.** That is how the implementation resolved it, and this Note is
the record saying so rather than leaving the resolution living only in a
moduledoc. `Encryptor.Ecto.Migrator.Pass`'s "Two ways to probe, and when the
cheap one is allowed" states the split, and `probe/3` implements it: the
`mode: :verify` clause and the clause for a target this package cannot read a
header claim out of both take the load attempt; every other pass reads the
header, and believes it only for an identity a load has already proven in that
batch (`lib/encryptor/ecto/migrator/pass.ex:33-75` and `:499-517`, ece
6027ac3). `Encryptor.Ecto.Migrator.verify/2`'s moduledoc says the same thing
from the caller's side - "It takes the expensive half of the one probe"
(`lib/encryptor/ecto/migrator.ex:262-267`, ece 6027ac3).

Two things follow that the decision text should not be read against. The probe
and the classification stay single: verification does not reimplement "is this
row in the target state?", it runs the same code with one mode flag, which is
what keeps the verifier's answer from drifting from the pass's. And decision
5's cost sentence is a rewrite-mode cost: an already-migrated row is skipped
without a key during a rewrite, while a verification spends the decrypt on
every row in scope by design, because that is the question `verify` exists to
answer.

Nothing in decision 5 or decision 10 changes. Decision 5's short-circuit
sentence is read as scoped to the rewrite modes (`:dry_run` and `:write`),
which is the only reading compatible with decision 10's "first-class pass",
and assumption A9 is unaffected.

This Note carries ADR-0002's status; the record was accepted on 2026-09-13 and
no decision text above changes.

## Note (2026-09-13): the closing sentence of the Note above dates the amendments, not the record

The Note above closes "This Note carries ADR-0002's status; the record was
accepted on 2026-09-13 and no decision text above changes." This record's
Status line reads `accepted (2026-08-27; the design is unchanged - the
assumption ...)`, and 2026-09-13 is the date the amendments at the head of this
file were accepted rather than the date this record was.

Read the sentence as "this Note carries ADR-0002's status; the amendments above
were accepted on 2026-09-13, and no decision text above changes." The Status
line is correct as written, nothing in the Note's substance about the probe
short-circuit changes, and no status word flips.

## Amendment (2026-09-13): an in-place declaration edit is migrated as two declarations, and the field options stay closed

Status: proposed

Decision 3's third bullet, the one beginning "**`from` and `to` may be the
same module with different params.**"
(`docs/adr/0002-migrator.md:372-377`, ece 1bee606), is **withdrawn in its
final clause**. The bullet's first sentence stands: a field moving from
`tenant: :none` to `tenant: :scope`, or gaining a `:context` pair, is a
context change and therefore a full rewrite even though no type module
changed. What is withdrawn is the claim that follows it - that "because the
migrator constructs both sides' params itself, this is expressible" by
naming the same module on both sides of the field spec.

### Why the same-module form does not express it

The source-side params change (`lib/encryptor/ecto/migrator.ex:455-462`,
`source_params/3`, and its comment block at `:425-441`; ece 1bee606,
landed in commit 235765f) builds a vault-backed source's params from the
`from:` type's *own* declaration - `from.init(schema: ..., field: ...)`,
with only the `:tenant` replaced by the plan's resolution strategy - which
is the same pair of moves `target_params/3` already made for the target
(`lib/encryptor/ecto/migrator.ex:488-497`, ece 1bee606). That is the right
answer for one of this package's own types, and decision 3's "the migrator
constructs both sides' params itself" survives it; the migrator does
construct both sides.

What does not survive is the inference drawn from it. When `from:` and `to:`
name the same module, both sides read **that module's current declaration**.
A declaration edited in place has exactly one current form, and the bytes
already on disk were written under the form it no longer has. There is no
params value the migrator could construct for the source side out of the new
declaration that describes the old bytes, so the same-module spelling cannot
express the in-place edit at all: it describes a rewrite from the new
declaration to the new declaration.

### The rule

**An in-place declaration edit is migrated as two declarations.** The host
keeps the old declaration as a module of its own - a second declaration of
the same column, under the old params - and names it `from:`; the edited
declaration is `to:`. This is the shape a cloak-to-encryptor plan's `from:`
module already takes (decision 3, and the worked example above), so the
migrator needs nothing new to run it: the source side reads the old
module's own declaration, the target side reads the new one, and the two
params values differ because the two declarations do.

This withdrawal is scoped to the *different params* clause. A `from:` and
`to:` that name the same module under the **same** declaration - the
single-tenant data-key rotation the worked example shows
(`docs/adr/0002-migrator.md:723-731`, ece 1bee606) - is a different case and
is not addressed here.

### `@field_options` stays closed

The field spec gains **no source-side params or context option**: no
`from_params:`, no `from_context:`, nothing else that would let a plan
describe the source side's declaration inline.
`@field_options`
(`lib/encryptor/ecto/migration.ex:167`, ece 1bee606) stays
`[:from, :to, :into, :source_authenticated, :validate]`. The two-declaration
form already expresses every in-place edit, in the host's own code, in the
same vocabulary the host wrote the declaration in; a source-side params
option would be a second spelling of a declaration, checked by this package
rather than by the compiler that checks the first one.

### The code half

`Encryptor.Ecto.Migration`'s moduledoc carries the same claim in the section
headed "`from:` and `to:` may be the same module"
(`lib/encryptor/ecto/migration.ex:65-73`, ece 1bee606): "the plan expresses
this by naming the same module on both sides". That paragraph is the code
half's site: it is rewritten to state the two-declaration form, and the
withdrawal is recorded as a `Changed` changelog fragment because it changes
what a host reading the published documentation would write.

This amendment **asserts the rule** and delegates the proof to a test in the
migrator run suite: a two-declaration plan whose `from:` module declares the
old params and whose `to:` module declares the new ones rewrites the rows,
and it is that test, not this record, that enumerates the declaration pairs.

Nothing else in decision 3 changes, no other decision changes, and no status
word above flips.

Provenance: campaign RF045, bead ece-lqz (the record half); the code half is
ece-4vz.

## Amendment (2026-09-13): the rotation pass - one option, a key-name comparison, and no new report class

Status: proposed

The worked example says that a single tenant's data-key rotation (R2) "is the
same tool with a filter and `from`/`to` naming the same module"
(`docs/adr/0002-migrator.md:723-731`, ece 6592581), and the operations table
assigns R2 to this record (`:275`, ece 6592581). The spelling is right and the
ownership is right. What the example does not say is that the pass it shows
**rewrites nothing**, and this amendment supplies the one thing that makes it
rewrite the rows it is pointed at.

### The defect

A rotation's `from:` and `to:` are one declaration under one vault, and A11 and
A12 say that is a vault which still decrypts the outgoing version:
"old and new versions coexist in one table for the duration of a pass", and
"prior versions stay decryptable until an explicit shred"
(`docs/adr/0002-migrator.md:581-582`, ece 6592581). So both probes answer
"already in the target state" for a row written under the previous version.
`load_probe/2` loads it, because the vault can
(`lib/encryptor/ecto/migrator/pass.ex:605-612`, ece 6592581). The header probe
accepts it, because
`against_declaration/2` compares the declared encryption context, the
`tenant_ref` presence and the algorithm suite and nothing else
(`pass.ex:562-581`, ece 6592581), and every one of those three is identical
across a rotation. `against_proof/4` then believes the claim as soon as one row
under that identity has loaded (`pass.ex:530-543`, ece 6592581). Every row is
counted `:already_target` and the pass writes nothing.

The data the fix needs is already being read. The header probe calls
`Encryptor.Message.describe/1`, which is documented for exactly this use - "for
a migration that needs to know which key version wrote a row"
(enc `lib/encryptor/message.ex:63`, in the `@doc` at `:56-92`, enc c50c9e1) -
and the writing key's name arrives in each entry of `encrypted_data_keys`
(enc `lib/encryptor/message/info.ex:43`, and the `key_name` paragraph at
`:28-31`, enc c50c9e1). It is already in the probe's hands: the identity
`against_proof/4` keys its proof cache on is `%{suite: ..., keys:
info.encrypted_data_keys}` (`pass.ex:205`, ece 6592581), so the cache already
separates a stale-version row from a current-version one. Only the comparison
is missing.

### The option

**A rotation is a rewrite pass with one option set: `writing_key:`, a single
key name as a string, defaulting to `nil`.** It joins `run/2`'s option list
(`lib/encryptor/ecto/migrator.ex:181-193`, ece 6592581); the field spec gains
nothing, and `@field_options` stays exactly as the preceding amendment left it
(`lib/encryptor/ecto/migration.ex:167`, ece 6592581). A rotation is a property
of a pass, not of a column.

The option is named for what it compares - the message's writing key - rather
than for the procedure it serves. Naming it `rotate:` would say that this
package performs the rotation, and it does not: A10 is that "the migrator never
selects a key version, it only causes a re-encrypt"
(`docs/adr/0002-migrator.md:580`, ece 6592581), and upstream ships no
`rotate/2` to delegate to (enc
`docs/adr/0005-rotation-and-crypto-shred.md:675`, enc c50c9e1). The option
states a fact about the rows, and the pass's answer to a scope already under
that key is an honest "nothing to do".

**`mode:` is unchanged, and there is no rotation mode.** Decision 7 stands
whole: `mode:` is required and is exactly one of `:dry_run` or `:write`
(`docs/adr/0002-migrator.md:441-442`, ece 6592581), `t:mode/0` stays
`:dry_run | :write` and `t:pass_mode/0` stays `mode() | :verify`
(`lib/encryptor/ecto/migrator.ex:129` and `:140`, ece 6592581). A rotation is a
`:dry_run` or a `:write` pass with `writing_key:` set; the dry run is the
census and the write is the rewrite, exactly as for every other pass.

**`writing_key:` requires a scope with one key holder.** A tenant's wrapping
key name is built as `"t/" <> tenant_ref <> "/v" <> version` (enc
`lib/encryptor/envelope.ex:573-574`, enc c50c9e1), so one literal name belongs
to one tenant and comparing it against another tenant's rows would classify
every one of them migratable. A `writing_key:` pass over a tenant-profile
vault therefore requires `only_tenants:` naming exactly one tenant
(`lib/encryptor/ecto/migrator.ex:81`, ece 6592581); over a global-profile
vault, whose scope holds one key holder already, it requires no tenant filter
and permits none. Anything else is refused at option validation, in the same
voice the existing filter refusals use. `only:` remains orthogonal and
permitted - a rotation narrowed to some of the plan's columns is a partial
rotation, and upstream's P2 preconditions already say what a missed column
costs (enc `docs/adr/0005-rotation-and-crypto-shred.md:363-366`, enc c50c9e1).

### The comparison, and where the current version comes from

**The comparison is name equality.** A row is in the target state when every
entry of the header's `encrypted_data_keys` claims `key_name` equal to the
`writing_key:` value; a row claiming any other name is not, and is rewritten.
The name is a version identity that travels in the clear, and it is a
pseudonym rather than a tenant identifier (enc
`lib/encryptor/message/info.ex:28-31`, enc c50c9e1), so carrying it in an
option discloses nothing the ciphertext did not already disclose to its holder.
It is a comparison target and never an authorization input, which is the
condition `describe/1`'s documentation attaches to every value it returns.

**The pass learns the current version from the option, which is to say from the
operator running the plan.** Of the three places it could come from, this is
the only one that exists:

- *Not the vault.* Upstream offers no keyless reader for "this tenant's current
  version". `Encryptor.Envelope.key_name/2` is `@doc false` and package-internal
  (enc `lib/encryptor/envelope.ex:569-574`, enc c50c9e1) and the only `version`
  resolver beside it is a private option reader, not a store query (enc
  `lib/encryptor/envelope.ex:714-723`, enc c50c9e1). Asking for such a reader
  would be new upstream surface, and this record does not ask for it.
- *Not the provider.* The migrator holds no provider, keyring or key-store
  handle, and decision 9's refusal to grow one survives the acceptance
  rewording of A14 (`docs/adr/0002-migrator.md:599-603`, ece 6592581). The
  current version lives in the host's key store, where the host itself inserted
  it: upstream's P2 step 1 provisions version *n+1* and "the host inserts the
  row" (enc `docs/adr/0005-rotation-and-crypto-shred.md:372-373`, enc c50c9e1).
- *So the plan's invocation.* The operator who has just run P2 step 1 knows the
  name of the version they minted, and step 2 is "downstream's tool and
  downstream's runbook" (enc
  `docs/adr/0005-rotation-and-crypto-shred.md:374-375`, enc c50c9e1). Stating
  the name is how the runbook hands that fact across the boundary. A stale name
  is self-correcting rather than dangerous: every row is classified migratable
  and rewritten, each rewrite encrypts under whatever version is actually
  current (A10), and a second pass under the right name reports a clean scope.

### The report class: the closed set is unchanged

**Rotation adds no class.** `Report.classes/0` stays the five it is today -
`:null`, `:already_target`, `:migratable`, `:migratable_unverified`,
`:undecryptable` (`lib/encryptor/ecto/migrator/report.ex:112-113`, ece
6592581) - and a rotation's rows are counted under them with their existing
meanings:

| The row | Class | Why |
|---|---|---|
| Column is `NULL` | `:null` | Unchanged; nothing to do |
| Header claims the `writing_key:` name | `:already_target` | The probe succeeded |
| Header claims some other name | `:migratable` | The probe failed and the `from` load succeeded - which it does, by A11 |
| Header claims some other name, on a field declaring `source_authenticated: false` | `:migratable_unverified` | The existing substitution, unchanged |
| Neither side loads | `:undecryptable` | Unchanged; an operator's decision |

`:migratable` is not a strained reading here. Its definition is "the probe
failed and the `from` load succeeded" (`report.ex:17-19`, ece 6592581), and for
a rotation both halves are literally true: the header comparison failed and the
outgoing version still decrypts. `:not_target` stays what it is, an internal
probe answer rather than a class, and nothing above needs it to become one.

### What rotation adds to the probe, and nothing else

**The version comparison is the only thing rotation adds.** It is one
additional predicate inside the header probe's claim check, before the claim is
handed on: when `writing_key:` is set and the header's names do not all match
it, `claimed/2` answers `:no` (`pass.ex:552-560`, ece 6592581) and the row is
rewritten without a load being attempted. Nothing else moves.
`against_proof/4` is untouched, and does not need touching, because a
stale-version header makes a different identity and never reaches a proof
entry made by a current-version one. `load_probe/2` is untouched, and is not
consulted for a row the comparison has already rejected, so rotation costs no
decrypt it did not already cost. The plan resolution, the cursor, the batching,
the concurrent-write re-probe and the write path are untouched.

One consequence is worth stating because it is a refusal rather than a
behaviour: a field whose target this package cannot read a header claim out of
takes the load probe instead (`pass.ex:514-515`, ece 6592581), and the load
probe cannot answer the rotation question at all. A `writing_key:` pass whose
scope contains such a field is refused at plan resolution rather than run with
that field silently answering "already in the target state" for every row.
That silence is the defect this amendment exists to remove, and it is not
acceptable one field at a time either.

### A rotation is verified by its own dry run, not by `verify/2`

`verify/2` takes a closed pair of options (`:sample` and `:prefix`,
`lib/encryptor/ecto/migrator.ex:195`, ece 6592581) and it does not gain
`writing_key:`. It could not use it: a verification takes the load probe by
design and, by A12, the outgoing version loads. So the acceptance check for a
rotation is a second `mode: :dry_run` pass with the same `writing_key:` value,
reporting an empty migratable count over the whole scope.

This is the census upstream's procedure already asks for - "no row remains
whose header names version *n*, per the same census as P1's verification"
(enc `docs/adr/0005-rotation-and-crypto-shred.md:383-384`, and the census
sentence at `:338`, enc c50c9e1) - and it is a census over stored bytes, which
is what a dry run with this option is. Nothing in decision 10 changes and
`verify/2`'s contract is not narrowed; a rotation simply is not the question
`verify/2` answers.

### Ownership

**The rotation model is upstream's; the probe and its option are this
record's.** `encryptor`'s ADR-0005 owns what a rotation is, what it costs, the
window between a rotation and a shred, and the order of the procedure - and
its P2 step 2 hands the row rewrite to this package by name, "nothing in this
package participates" (enc
`docs/adr/0005-rotation-and-crypto-shred.md:374-375`, enc c50c9e1). This
record owns the pass that performs step 2: the comparison, the option that
turns it on, the scope rule, the classification, and the refusals. The
operations table's assignment of R2 to this record (`:275`, ece 6592581)
stands, and R1 and R4 stay upstream's, unchanged.

### The code half

The code half adds `:writing_key` to `run/2`'s known options and its option
validation, threads it into the pass, and adds the one predicate in the header
probe's claim check. The worked example's R2 invocation gains the option. The
addition is recorded as an `Added` changelog fragment, because it is a public
option a host reading the published documentation would write.

This amendment **asserts the rules above** and delegates the proof to a test in
the migrator run suite: a row written under an outgoing version, under a vault
that decrypts both versions, is classified `:already_target` without
`writing_key:` and `:migratable` with it, and is rewritten under the current
version by a `mode: :write` pass. It is that test, not this record, that
enumerates the cases.

Nothing in the decision text above changes, no other amendment changes, and no
status word above flips.

Provenance: campaign RF045, bead ece-a7s (the record half); the code half is
ece-uiw.

## Note (2026-09-14): what the same-module spelling loses varies by the edit, and `source_params/3` has two paths rather than one

The amendment above argues, in "Why the same-module form does not express it"
(`:944-964`), that "there is no params value the migrator could construct for
the source side out of the new declaration that describes the old bytes, so
the same-module spelling cannot express the in-place edit at all"
(`:960-964`). The rule it supports is right and unchanged. The inference is
over-general: for one of the two edit kinds that sentence covers, the
same-module spelling still *reads* the old bytes, and what it loses is the
description rather than the read.

**The rule is one rule and it covers both kinds.** An in-place declaration
edit is migrated as two declarations whatever the edit was; the table says
only what the one-module spelling would have cost in each case.

| The edit | Readable under the edited declaration's params? | What the same-module spelling loses |
|---|---|---|
| A declared `:context` pair added to an otherwise unchanged declaration | Yes | The description: the plan says it is rewriting from the edited declaration to itself, so nothing in the diff names the bytes being read |
| An edit that moves which key wrapped the bytes - a different `:vault`, or a `:tenant` strategy that changes the key holder | No | The read as well as the description: the old bytes do not open under the edited declaration's params at all |

The first row is a fact about this package's format rather than a
convenience: a declared context pair is composed into the message at encrypt
and is not enforced at decrypt, so the edited declaration's params still open
bytes written before the pair was declared. The run suite carries both halves
- the two-declaration plan the rule asks for, whose `from:` is
`Encryptor.Ecto.TestTypes.Pan` and whose `to:` is the same column declared
again with one more context pair
(`test/support/test_engine_plans.ex:295-320` and
`test/support/test_types.ex:122-130`, ece eae0fd3), and the note above its
tests recording that pointing that plan's `from:` at the edited declaration
leaves the test green (`test/encryptor/ecto/migrator_run_test.exs:846-853`,
ece eae0fd3).

**The cloak analogy in "The rule" is a spelling analogy and not a code-path
identity.** That paragraph says the two-declaration form "is the shape a
cloak-to-encryptor plan's `from:` module already takes" (`:971-972`). The
shape is the same; the path through the migrator is not. `source_params/3`
(`lib/encryptor/ecto/migrator.ex:545-552`, ece eae0fd3) answers `nil` for a
`from:` this package cannot prove is one of its own - a cloak reader either
exports no `init/1` or returns params `ours?/1` rejects (`:661-665`, ece
eae0fd3) - and `source!/3` then leaves the migrator's own identifying
resolution in place for the source side (`:532-540`, ece eae0fd3). A
two-declaration `from:` is one of ours, so it takes the `from.init/1` branch
through `ours_or_nil/2` (`:554-557`, ece eae0fd3) and the old declaration's
own params are merged over that resolution. The `from:` module is a host
module in both cases; only in the second does the migrator read the
declaration it carries.

This Note asserts the readings above and leaves the enumeration to the
migrator run suite's in-place-edit tests: it is those tests, not this record,
that say which edits the two-declaration form rewrites. No decision changes,
neither amendment's rule changes, and no status word above flips.

Provenance: campaign RF048.

## Note (2026-09-14): five readings of the rotation amendment above, and a header naming no keys is not the target

The amendment above is unchanged and its rules stand. Five of its sentences
read past the code they describe or stop short of it; each is re-anchored
here, by addition.

**1. "Rewritten without a load being attempted" is the target load.** The
probe paragraph says that when the header's names do not all match, the claim
check answers `:no` "and the row is rewritten without a load being attempted"
(`:1161-1165`). The load it skips is the *target* probe: `probe/3`'s header
arm (`lib/encryptor/ecto/migrator/pass.ex:546-551`, ece eae0fd3) answers
`:not_target` without calling `load_probe/2` (`pass.ex:670-678`, ece
eae0fd3), which is exactly what the two sentences after it say, and they are
right. The rewrite that follows still reads the source side: `migrate/6`
(`pass.ex:700-707`, ece eae0fd3) goes through `load_source/3` (`:712-718`) to
`read_source/3` (`:744-747`) and `Encryptor.Ecto.Migrator.Source.load/3`. A
rotation spends one decrypt per rewritten row rather than none.

That sentence's own cite has moved with the code half: the predicate it calls
`claimed/2` (`pass.ex:552-560`, ece 6592581) is `claimed/3` today
(`pass.ex:587-595`, ece eae0fd3), having taken the `writing_key` argument, and
it hands the surviving claim to `claimed_by/3` (`:597-603`, ece eae0fd3).

**2. The acceptance check beneath the R2 example belongs to the cloak plan.**
The refining line the amendment added to the worked example (`:733-735`) is
followed by "And the acceptance check:" and a `verify/2` transcript
(`:737-742`). That transcript runs `MyApp.Encryption.CloakMigration`: it is
R1's check, not R2's, and a sequential reader should not take it for the
rotation's. A rotation's acceptance check is a second `mode: :dry_run` pass
carrying the same `writing_key:` and reporting an empty migratable count over
the whole scope, which is what "A rotation is verified by its own dry run, not
by `verify/2`" (`:1182-1197`) says; `verify/2` does not take the option.

**3. The scope rule is refused in two places, and only one of them is option
validation.** "Anything else is refused at option validation" (`:1094`) holds
for the half that is a fact about the option list - a tenant filter given
beside `writing_key:` names exactly one tenant or it is wrong - and that is
where `options!/1` raises (`lib/encryptor/ecto/migrator.ex:704-707`, ece
eae0fd3). Which of "one" and "none" a given vault requires is not knowable
until the target's params are resolved, so that half is refused at plan
resolution instead: `rotatable!/5` (`migrator.ex:494-511`, ece eae0fd3),
called from `pass!/5` (`:396`, ece eae0fd3). Same voice, same pass, two
moments.

**4. The worked example's R2 invocation still does not carry the option.**
"The worked example's R2 invocation gains the option" (`:1216`) states the
code half's intent; what landed re-anchors the paragraph rather than editing
the fenced block, so the invocation at `:726-731` still reads `mode: :write,
only_tenants: ["acct_A"]` and the line at `:733-735` points at it. For a
reader who wants the whole shape in one place, the rotation form of that
invocation is:

```elixir
Encryptor.Ecto.Migrator.run(MyApp.Encryption.Rotate,
  mode: :write,
  only_tenants: ["acct_A"],
  writing_key: "t/acct_A/v2"
)
```

The key name's form is upstream's - `"t/" <> tenant_ref <> "/v" <> version`,
quoted at `:1086-1088` - and the value above is an illustration rather than a
fact about any deployment.

**5. The key-name comparison is not vacuous for a header naming no keys.** The
comparison sentence says a row is in the target state "when every entry of the
header's `encrypted_data_keys` claims `key_name` equal to the `writing_key:`
value" (`:1102-1104`). Read literally over an empty list that is vacuously
true, which would make a header naming no keys the target. **The rule is the
other reading: a header naming no keys at all is not in the target state.**
`written_under?/2` says so - its matching clause requires at least one entry
(`pass.ex:622-623`, ece eae0fd3) and its final clause answers `false`
(`:625`, ece eae0fd3) - and the comment above it (`:613-618`, ece eae0fd3)
carries the reason together with the fact that a message of this format
carries at least one entry, so the arm is unreachable rather than
load-bearing. A rotation's whole job is that no row in scope still claims
another version, and a row claiming nothing has not been shown to claim this
one.

This Note asserts the readings above and leaves the enumeration to the
migrator run suite's rotation tests. No decision changes, none of the
amendment's rules changes, and no status word above flips.

Provenance: campaign RF048.
