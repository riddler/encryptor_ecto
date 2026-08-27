# ADR-0002: the migrator - a plan-driven, resumable, compare-and-swap row rewriter

Status: accepted (2026-08-27; the design is unchanged - the assumption
table and open questions carry their acceptance resolutions, and A14 is
reworded per enc-ADR-0005)

## Proposed amendments (2026-08-27)

Status: **proposed**. Acceptance is the operator's; the decision text below
is unchanged. These fold ADR-0004's extensions to this record into this
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

**Q5. Multi-repo, per-tenant prefix, and sharded hosts.** A plan names one repo
and no prefix. ADR-0001 decision 4 deliberately excludes the prefix from the
encryption context, which means ciphertext is portable across prefixes and the
migrator only needs to *visit* every prefix, not vary its context per prefix.
Whether that visiting belongs in the plan (a `prefixes:` list), in the caller (a
loop over `run/2`), or nowhere yet is open. Owner: this repo, before
implementation.

**Q6. Ordering guarantees for non-integer and composite primary keys.** Keyset
pagination needs a total order on the primary key. UUIDv4 keys order fine but
scatter over the index; composite keys need tuple comparison the query builder
does not express uniformly across adapters. The founding implementation may
restrict itself to single-column primary keys and say so. Owner: this repo,
before implementation.

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
