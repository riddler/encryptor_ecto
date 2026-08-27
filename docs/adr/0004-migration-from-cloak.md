# ADR-0004: migration from a prior encryption scheme, with cloak_ecto as the named case

Status: accepted (2026-08-27)

## Context

ADR-0001 argues that this package's type surface should be `cloak_ecto`'s
shape byte-for-byte, and gives the reason in one sentence: **the shape is the
migration story.** ADR-0002 then designs the engine that performs the
migration - a plan-driven, probe-first, compare-and-swap row rewriter that
runs against live traffic - and its worked example is titled "cloak to
encryptor". Between them, most of this record's subject is already decided.

What is not decided is everything that only appears when a real host actually
does it. ADR-0002 owns the *engine*; this record owns the *adoption*: the
concrete binding of that engine to the library hosts are actually leaving, the
operator-facing task family and its grammar, the semantics of the mixed window
that ADR-0001's `legacy:` option opens, what is honestly reversible and where
the point of no return sits, and the documentation set that carries all of it.

Four forces shape it.

**The migration is a security operation performed on live production data by
someone reading a page.** The person running it is holding a shell against the
one table in the system whose contents matter most, and their evidence that it
worked is a number printed by the tool that did it. Every decision below leans
toward giving that person a rehearsal they can trust, a signal they can check
without the application's cooperation, and a runbook whose steps say plainly
which ones can be taken back.

**A migration affordance is a security downgrade for as long as it is on.**
ADR-0001's `legacy:` option and ADR-0002's both-libraries window exist so that
the migration needs no downtime. What they cost, while they are on, is the
property the whole stack is for: a row that still holds legacy bytes is read
through the legacy scheme, with the legacy scheme's key model and no
encryption context binding it to its row. Naming that cost in the record - and
making the window's end a thing the host can *detect* rather than remember -
is most of what this record adds over ADR-0002 decision 8.

**This package must not learn what cloak's bytes look like.** It is tempting
to add a cloak decoder here, because it would make the migration a one-liner.
It would also make this package's compatibility surface a third-party
library's private format, versioned by someone else, tested against nothing.
The alternative is available and better: the host already has working code
that reads its own bytes - its own type modules - and ADR-0002 decision 8
already declined the dependency. This record makes that refusal structural
rather than incidental.

**"From cloak" is one instance of "from something else".** Hosts arrive from
`cloak_ecto`, from a hand-rolled `Ecto.Type` around `:crypto`, and from a
plaintext column that was never encrypted at all. Designing for cloak
specifically would produce a tool that serves the loudest case and refuses the
others; designing for the general case and *naming* cloak as the worked
instance costs nothing, because the general mechanism - "call the module that
can already read these bytes" - is the same mechanism.

One thing the research for this record turned up changes its shape, and is
stated here because it is the reason decision 3 exists at all: **`cloak`
ships an unauthenticated cipher, and a host on it cannot tell corruption from
data.** `Cloak.Ciphers.AES.CTR` is a stream cipher with no authentication tag
(C8 below), so its `load/1` fails only when the tag prefix does not match or
the remainder is too short - never because the bytes decrypt to nonsense. Every
probe-based classification in ADR-0002 assumes a failed decrypt is a *signal*,
and against CTR it is not one. That assumption survives for AES.GCM hosts and
does not survive for CTR hosts, and a record that migrated both the same way
would launder corrupt rows into the new format at full speed.

## Decision

**1. This record adds no engine, and no cloak-specific code path.** Cloak
support is a *configuration* of ADR-0002's migrator, expressed entirely in the
host's plan module. Nothing in `lib/` branches on cloak, imports cloak, or
recognizes a cloak message. `cloak_ecto` does not appear in this package's
`mix.exs` under any dependency category, including `:optional` and `:only` -
ADR-0002 decision 8 says so and this record binds it.

The rule has a specific bite worth naming, because the shortcut is right
there. `cloak_ecto`'s own migrator finds its fields by testing whether a
schema's type module exports `__cloak__/0` (C9), which is a precise, cheap
detector this package could adopt in one line. It does not, and decision 7
uses a generic heuristic that over-reports instead. One line of another
library's private interface is still a dependency on it, and the thing it
would buy - a slightly tidier generated skeleton - is not worth a compile-time
coupling to a function nobody promised to keep.

The consequence to state up front: **everything below works identically for a
host migrating off a hand-rolled type.** Cloak is the named case because it is
the common one, not because it is a supported integration.

**2. The pre-migration reader is a `Source`, and `Source.EctoType` adapts any
module that can already read the bytes.** ADR-0002's typespecs name
`Encryptor.Ecto.Migrator.Source` with a single callback,
`load(binary(), params) :: {:ok, term()} | {:error, term()}`. This record
fixes what satisfies it and how a plan names one.

A plan's `from:` accepts three things:

| `from:` value | Meaning |
|---|---|
| A module implementing `Ecto.Type` (arity-1 `load/1`) | Adapted by `Source.EctoType`. This is every `cloak_ecto` type module (C1) and every hand-rolled one |
| A module implementing `Ecto.ParameterizedType` (arity-3 `load/3`) | Adapted by `Source.EctoType`, with params constructed by the migrator per ADR-0002 decision 3 |
| A module implementing `Source` directly | Used as-is. `Source.Plaintext` (ADR-0002 decision 8) is the one this package ships |

The adaptation is resolved **at plan compile time**, not per row: the plan
macro ensures the module is loaded and checks `function_exported?/3` for each
arity, raising a `CompileError` naming the field if neither shape is present.
ADR-0002 decision 2 already promised that a plan which would fail on row one
fails at `mix compile`; this is the part of that promise that concerns the
source side.

Three properties follow, and they are the reason for the indirection:

- **The host's own code reads the host's own bytes.** The module doing the
  legacy load is the module the host has been running in production, with the
  host's cipher configuration, the host's key material, and the host's own
  test suite behind it. This package's correctness obligation on the legacy
  format is exactly nil.
- **A `{:error, reason}` from a source is data, not an exception.** ADR-0001
  decision 6 makes the *types* raise, which is right for application code and
  wrong for a migrator that must classify a failure and keep a report
  (ADR-0002 decisions 7 and 11). `Source.EctoType` therefore converts: an
  arity-1 `:error` return (which is what a cloak type gives on a failed
  decrypt, C2) and any raise from the adapted module both become
  `{:error, reason}` at the `Source` boundary, and the migrator classifies the
  row `:undecryptable`. The rescue is scoped to the single `load` call on a
  single row - it is not a rescue-to-default at a leaf, and nothing silently
  proceeds: ADR-0002 decision 11's default is still to halt the pass.
- **A zero-arity function returned by a source is invoked once, and the result
  is the plaintext.** Deferred decryption is a real convention among legacy
  types - `cloak_ecto`'s `:closure` option is exactly it (C10) - and a source
  that returns a closure would otherwise have the migrator re-encrypt the
  *function* rather than the value. The unwrap is stated as a generic rule
  about the `Source` contract, not as cloak handling, and it inherits ADR-0002
  decision 11's prohibition in full: the unwrapped value is never logged,
  inspected, or put in an error.

**3. A legacy cipher without authentication is a named limitation, and the
plan says so out loud.** This is the decision the research forced, and it is
stated before the mechanics because it changes which hosts can use them.

ADR-0002's whole classification rests on a failed decrypt being informative.
For an AEAD cipher it is: garbage in produces an authentication failure, and
`:undecryptable` means what it says. For an unauthenticated stream cipher it
is not. `Cloak.Ciphers.AES.CTR` (C8) rejects bytes only on a tag mismatch or a
short remainder; anything past that decrypts to *something*, and that
something is what the migrator would faithfully re-encrypt into the new
format - permanently, authenticated, and looking exactly like a successful
migration in the report.

So:

**3a.** A plan field may declare `source_authenticated: false`. It is not a
capability flag; it is an acknowledgement, and it changes two behaviours.
First, the migrator's report distinguishes `:migratable` from
`:migratable_unverified` for that field, and `verify` counts them separately,
so the operator's evidence never says "verified" about rows nothing verified.
Second, the pass refuses to run in `--mode write` for that field unless a
`validate:` function is also declared.

**3b.** `validate:` is a host-supplied `(term() -> boolean())` applied to the
loaded plaintext before it is re-encrypted. It is the host's own knowledge of
its own data doing the work an AEAD tag would have done: a tax identifier is
nine digits, a note is valid UTF-8, a serialized map parses. A row failing it
is classified `:undecryptable` and handled by ADR-0002 decision 11 exactly as
any other failure. This is deliberately weak and deliberately the host's: this
package cannot know what a valid value looks like, and a generic check
(printable? UTF-8?) would be a false reassurance rather than a control.

**3c.** Where the host kept a deterministic hash column beside the field - and
a cloak host very often did, because that is cloak's own answer to querying
(C5) - the guide names it as the strongest validator available: `validate:`
recomputes the legacy hash over the loaded plaintext and compares it to the
stored column. That is a genuine integrity check over the exact bytes being
migrated, it needs no new machinery, and it is free. It is also the reason
decision 9 puts *dropping* that column after the rewrite rather than before.

**3d.** None of this applies to an AEAD legacy cipher, which is the common
case: a `Cloak.Ciphers.AES.GCM` host (C8) declares nothing, gets the ordinary
classification, and reads decision 3 as background.

**4. `legacy:` binds to the same reading, and its fallback is narrow, ordered,
and never a dump path.** ADR-0001 acceptance amendment 4 grants the option and
states its shape: load through the named legacy type when the primary load
fails, always dump through the new type. This record fixes the three details
that decide whether it is safe.

**4a. Order and trigger.** The primary load is attempted first, always. The
legacy load is attempted **only** when the primary load fails with a
message-shaped failure - the conditions ADR-0001 decision 6 maps to
`Encryptor.Ecto.DecryptError`. It is **not** attempted for
`MissingTenantError` or `MissingContextError`: those are host
misconfiguration, they are loud on purpose, and a fallback that answered them
with a successful legacy read would convert a configuration bug into a silent
year of un-migrated rows.

The order is also what makes the fallback cheap in the steady state. It costs
one failed decrypt per legacy row and nothing at all per migrated row, and the
population of legacy rows is monotonically shrinking for the whole window.

**4b. Which error survives.** If both loads fail, the exception raised is the
**primary** `DecryptError` - the legacy attempt's reason travels in the same
non-contractual `:engine`-style detail field ADR-0001 acceptance amendment 2
established, and is never matched for control flow. Raising the legacy error
would report a self-expiring compatibility shim as the cause of what is
usually a genuine integrity event.

**4c. Nothing writes through legacy, ever.** `dump/3` has no legacy arm and
never will. A value read through the legacy path and written back is written
in the new format, which is what makes ordinary application traffic migrate
rows on its own during the window.

**5. The mixed window is a named security downgrade with a detectable end.**
While `legacy:` is set, a row that has not yet been rewritten is read under the
legacy scheme's rules. For a `cloak_ecto` host that means, concretely, that
those rows have no encryption context: the anti-substitution property
ADR-0001's context calls the main reason to prefer this stack over cloak does
not hold for them, and neither does per-tenant key separation, because cloak's
`Ecto.Type` layer
has no per-user or per-tenant key model at all (C7). The window does not
weaken any *migrated* row; it means the guarantee is per-row until the pass
finishes.

Three commitments follow.

- **`legacy:` is documented at the option as self-expiring**, with the removal
  step named in the runbook (decision 8, step 8) rather than left to a host's
  memory. ADR-0002's consequences already observe that nothing enforces the
  deletion; this record's answer is to make the signal unmissable rather than
  to invent enforcement.
- **The end of the window is detected, not remembered.**
  `Encryptor.Ecto.Migrator.verify/2` exiting zero over `sample: :all` is the
  primary signal, and it needs no new machinery. Alongside it, a type carrying
  `legacy:` emits a telemetry event on every load that fell through to the
  legacy path, `[:encryptor_ecto, :legacy_load]`, whose measurements are a
  count and whose metadata is the table and the column **and nothing else** -
  no value, no bytes, no reason, no tenant. A host wires it to a counter and
  drops `legacy:` when it has read zero for a full retention period. ADR-0002's
  consequences say that any future logging, telemetry, or progress-reporting
  addition to *the migrator* is a security review rather than a feature; this
  event is on the type rather than the migrator, and this decision extends the
  same standard to it rather than treating the distinction as an exemption.
  Its metadata set is closed here, and widening it is that review.
- **The window is per-field, and so is its end.** A host with twelve encrypted
  columns finishes eleven of them and still has one legacy reader open. The
  telemetry metadata carries table and column precisely so the last one is
  identifiable rather than the whole set being held hostage to the slowest
  table.

**6. The task family is fixed at four verbs, and the library function is the
real interface.** ADR-0002 decision 1 already decided that the mix tasks are
thin parsers over `Encryptor.Ecto.Migrator`, because a release has no Mix.
This record fixes the family and closes it:

| Task | Wraps | Reads or writes |
|---|---|---|
| `mix encryptor.ecto.migrate` | `Migrator.run/2` | Reads always; writes only under `--mode write` |
| `mix encryptor.ecto.verify` | `Migrator.verify/2` | Read-only |
| `mix encryptor.ecto.gen.migration` | - | Writes one Ecto migration file into the host's tree (the checkpoint table, ADR-0002 decision 6) |
| `mix encryptor.ecto.gen.plan` | - | Writes one plan module skeleton into the host's tree |

The grammar, fixed here so that the runbook and the tasks cannot drift:

```
mix encryptor.ecto.migrate PLAN --mode dry-run|write
                                [--batch-size N] [--resume] [--no-resume]
                                [--only Schema:field,Schema:field]
                                [--only-tenant ID] [--except-tenant ID]
                                [--on-error halt|continue]

mix encryptor.ecto.verify PLAN [--sample N | --sample all]
```

`PLAN` is the plan module, positional and required. `--mode` is required and
has no default, per ADR-0002 decision 7. Every other flag maps one-to-one onto
an option in ADR-0002's `opts()` type; the tasks add no capability the library
function does not have, which is what keeps the release path a first-class one
rather than a degraded one.

Exit codes, because a runbook step that says "check it worked" needs something
to check: **0** the pass completed with no failures and (for `verify`) every
row `:already_target` or `:null`; **1** the pass ran and found something -
failures recorded under `--on-error continue`, or rows not in the target
state; **2** usage error, plan would not compile, no mode given. A dry run
that finds `:undecryptable` rows exits 1, because "the rehearsal found a
problem" is not success.

Four differences from `mix cloak.migrate.ecto` are worth naming, because an
operator arriving from it will expect its behaviour and three of these are
places where that expectation is actively unsafe here.

| | `mix cloak.migrate.ecto` (C6) | Here |
|---|---|---|
| What to migrate | Application config (`:cloak_repo`, `:cloak_schemas`) or `-r`/`-s` flags | A plan module, in code, reviewed in a diff (ADR-0002 decision 2) |
| Concurrency | `Task.async_stream` over rows, each in its own transaction | One process, one repo, batched (ADR-0002 decision 12) |
| Row safety | `SELECT ... FOR UPDATE` row lock held across the re-encrypt | Compare-and-swap on the ciphertext column, no lock (ADR-0002 decision 4) |
| Rehearsal | None; the task writes | `--mode` is required and has no default |

The concurrency row is the one that bites. `cloak_ecto`'s own documentation
warns that its migrator can exhaust the connection pool and recommends a
dedicated repo with a small pool. That advice is correct for that tool and
must not be carried over as a *requirement* here, where the pass is
single-process by decision and needs one connection; a host that provisions a
throttled migration repo out of habit gets a slow pass and concludes this tool
is slower than it is.

**7. `gen.plan` generates a skeleton that does not compile until a human
finishes it.** The generator reads the host's schema modules, finds fields
whose type module is not a built-in Ecto type, and emits a plan with one
`rewrite` block per schema and one `field` line per candidate. It does three
things that look like defects and are not:

- **It emits `tenant_from :TODO_tenant_column`**, which fails the plan's
  compile-time check (ADR-0002 decision 2 requires `tenant_from` to name a
  real column). Which column identifies the tenant is a fact about the host's
  domain model that no generator can read off a schema, and the failure mode
  of guessing it is re-encrypting every row under the wrong key. A skeleton
  that compiles is a skeleton somebody runs.
- **It emits `to:` as a comment, not a value.** The generator cannot know
  which target type module the host intends, and half-guessing produces a diff
  that looks reviewed.
- **It over-reports.** Per decision 1 it does not use `__cloak__/0` or any
  other library's marker, so a custom non-encrypted `Ecto.Type` shows up as a
  candidate. For a tool whose whole claim is "here are the encrypted fields
  you forgot you had", a false positive a human deletes is strictly better
  than a false negative nobody sees.

Everything consequential stays a decision written by hand into a file that
goes through code review, which is ADR-0002 decision 2's argument for the plan
being code at all.

**8. The runbook is the deliverable, and step 5 is the point of no return.**
ADR-0002 decision 8 gives the five-step sequence. The how-to guide (decision
10) expands it to the numbered form below, and this record fixes the sequence
so the guide is a rendering of a decision rather than a set of suggestions:

| # | Step | Reversible by |
|---|---|---|
| 0 | Finish or abandon any in-flight legacy key rotation. A cloak vault mid-rotation has two ciphers configured and both are readable through the same type module (C4), so nothing here breaks - but two migrations at once make one report | Nothing written |
| 1 | Provision vault key material for every tenant | Nothing to reverse; no host data touched |
| 2 | Deploy with both libraries in the tree, schema fields still naming the legacy type modules | Reverting the deploy |
| 3 | Deploy the type modules switched to `use Encryptor.Ecto.*` with `legacy:` set. New writes are new-format; reads tolerate both | Reverting the deploy, **while no row has been written in the new format** |
| 4 | `--mode dry-run`. Read the classification. Resolve every `:undecryptable` row, and every `:migratable_unverified` count, before proceeding | Nothing written |
| 5 | `--mode write`. **Point of no return** | A reverse plan (below) or a restore |
| 6 | `mix encryptor.ecto.verify --sample all`. Exit 0 is the acceptance test | n/a |
| 7 | Adopt blind indexes and drop the legacy hash columns, if applicable (decision 9) | Dropping the new columns; the old ones are gone |
| 8 | Drop `legacy:`, drop the legacy library from `mix.exs`, delete the plan module, in one named commit | Reverting the commit |

Step 3 is where reversibility actually ends in practice, not step 5: the
moment the new type modules are live, ordinary application traffic starts
writing new-format rows. The table says step 5 because that is where it
becomes *irreversible in bulk*, and the guide says both.

**Reverse migration is expressible and documented, not built.** Because
ADR-0002 decision 3 constructs both sides' params itself and `from`/`to` are
symmetric, a plan with the modules swapped is a valid plan, and running it
walks the table back. This record documents that as the emergency path and
commits to no tooling for it: an automated rollback of a security migration is
a mechanism whose only rehearsal is the emergency it exists for. Its
preconditions are stated in the guide - the legacy key material must still
exist and the legacy modules must still be in the tree, which is precisely why
step 8 is the last step and not an earlier one.

**9. Legacy lookup columns are replaced, not supplemented, and the migrator
does not do it.** A host arriving from cloak usually arrives with an
exact-match lookup problem, because cloak's answer to it is a sibling
deterministic column (C5) and hosts that needed lookups have one. There are
three cases and they are not equivalent:

| Legacy column | What a dump discloses | Disposition |
|---|---|---|
| `Cloak.Ecto.SHA256` - unsalted, unkeyed | Every value whose plaintext is guessable, to anyone holding the dump and no key at all | **Must be dropped.** ADR-0003's context calls this out as the folk pattern it exists to replace |
| `Cloak.Ecto.HMAC` / `PBKDF2` - keyed, one global key | Nothing without the key; with the key, equality across every tenant and every table sharing it | Replaced. It is a real blind index with ADR-0003's `scope: :global` leakage and none of its domain separation |
| None | - | Adopt or do not, freely |

Adoption is a separate, sequenced pass, for two reasons that are ADR-0002's
and ADR-0003's rather than this record's. The migrator writes ciphertext
columns only, below the schema layer, with no changesets (ADR-0002 decision
3); a blind index is computed by a changeset helper from plaintext (ADR-0003
decision 5) into a column the host declared in its own migration. And index
backfill is ADR-0003 decision 7's step 3 - batched, in tenant scope - run
after the ciphertext rewrite is verified, so that a failure in either is
attributable to one of them.

The sequencing rule that is this record's: **the legacy column is dropped in
the same migration that stops writing it, and after decision 3c has finished
using it.** Adding a keyed index beside an unkeyed one fixes nothing while the
unkeyed one remains; and dropping the unkeyed one before the rewrite throws
away the best validator a CTR host has. Both orderings are wrong in a way that
is invisible at the time, so the runbook fixes the order. A dump taken before
the drop still contains the old column, which is a fact about backups the
guide states and this package cannot fix.

**10. The documentation set is three pages, and there is deliberately no
tutorial.** The Diataxis split, with each page's job stated so a later
contributor does not blur them:

| Page | Type | Job |
|---|---|---|
| `docs/guides/migrate-from-cloak.md` | How-to | Decision 8's runbook, executable start to finish by an operator who already understands the target state. Numbered, with the command for each step in both `mix` and release-`eval` form, the expected output, and what to do when it differs |
| `docs/explanation/moving-off-cloak.md` | Explanation | What changes *semantically*: per-tenant keys, the encryption context and the anti-substitution property it buys, fail-closed tenant scope and the boundary audit it implies (ADR-0001 decision 5b), crypto-shredding and what `tenant: :none` gives up, why encrypted columns are not queryable, and what a blind index does and does not restore |
| The tasks' `@moduledoc`s | Reference | The flag tables of decision 6, rendered by ExDoc. The grammar lives with the code that parses it |

**No tutorial.** A tutorial's promise is a safe place to practice, and the
practice article for a destructive migration would either operate on a host's
real data - which is the thing it is supposed to teach them to be careful
with - or on a toy that omits every property that makes the real one hard
(live traffic, tenant scope, undecryptable rows). The dry run *is* the
rehearsal, it happens against the host's own data, and it is step 4 of the
how-to. Building a fake one alongside it would compete with it.

The how-to leads with the release `eval` form, not `mix`. ADR-0002 decision 1's
argument - that a rotation runnable only from a developer's laptop against
production credentials is the opposite of a control - is undermined by a guide
whose examples are all `mix`, and documentation that quietly contradicts a
decision is how the decision gets lost.

**11. What this record refuses.** Each of these has been considered and is
declined on the record, so that a later contributor finds an argument rather
than an omission:

- **No `use Encryptor.Ecto.CloakCompat`.** A single module that reads the
  host's cloak config and produces a working legacy type would be the
  friendliest possible surface, and it would make this package a consumer of
  another library's configuration schema.
- **No cloak message decoder, and no format detection by byte inspection.**
  ADR-0002 decision 10's SQL census works on *this* package's message header
  (its assumption A8); distinguishing "not one of ours" from "one of theirs"
  needs nothing about their format, and the census is written as
  target-or-not for exactly that reason. There is a concrete trap here that
  the guide records: cloak's envelope opens with a reserved `0x01` byte (C3),
  and this package's messages open with a version byte of their own, so a
  census keyed on the *first byte alone* can read as identical across both
  formats. The census query compares a wider prefix, and the guide says why.
- **No key material migration.** Converting a cloak vault's key into vault key
  material is `encryptor`'s territory and an operator's provisioning step. A
  host whose legacy key is *gone* has rows that are already shredded; the
  migration cannot help and the guide says so in its prerequisites.
- **No automatic detection that a host is on cloak.** `gen.plan` finds
  encrypted-looking *fields*; it does not identify the library, and its output
  is the same for a hand-rolled type (decision 1, decision 7).
- **No support for a legacy scheme that cannot be read by an
  `Ecto.Type`-shaped module.** Anything else - a sidecar service, a stored
  procedure - is expressible by the host writing a `Source` implementation, and
  needs nothing from this package but the behaviour it already publishes.
- **No generic plaintext validator.** Decision 3b's `validate:` is the host's
  or it is absent. A built-in "looks like text" check would be reassurance
  without a guarantee, on the one path where the guarantee is the point.

## Facts assumed about cloak_ecto

ADR-0001 and ADR-0002 carry tables of assumptions about the *upstream* vault,
resolved at acceptance. These are different in kind: they are facts about a
third-party library this package deliberately does not depend on, observed
from its source rather than promised by it. They are listed because most of
the decisions above lean on one or more of them - the table's last column says
which - and because a future reader deserves to know which parts of this
record are observations about someone else's code and how firmly each was
established.

**None of them is load-bearing on this package's code.** Decision 1 means no
`lib/` file changes if any turns out wrong or goes stale; what changes is a
paragraph of the guide. The one exception is C8, which is load-bearing on a
*decision* (3) rather than on a module.

| # | Observed about `cloak` / `cloak_ecto` | Confidence | Used by |
|---|---|---|---|
| C1 | The Ecto types are plain `Ecto.Type` (not `Ecto.ParameterizedType`), generated by `use Cloak.Ecto.Binary, vault: ...`, with arity-1 `cast/1`, `dump/1`, `load/1` | Read from source | 2 |
| C2 | `load/1` returns `:error` on a failed decrypt rather than a garbage value | Read from source | 2, 4a |
| C3 | The stored bytes open with a tag envelope - a reserved `0x01` byte, a length byte, then the cipher's configured tag string - and a vault selects its cipher by matching that tag, so bytes this package wrote are not readable by a cloak type | Read from source | 2, 11 |
| C4 | A vault may carry several labelled ciphers at once and decrypts through whichever tag matches, which is how a cloak-internal rotation works | Read from source | 8, step 0 |
| C5 | `cloak_ecto` offers no blind index on the encrypted types, and answers exact-match lookups with a sibling deterministic column: `Cloak.Ecto.SHA256` (unsalted, unkeyed) with `HMAC` and `PBKDF2` documented as the stronger alternatives | Read from source and README | 3c, 9 |
| C6 | The migrator task is `mix cloak.migrate.ecto`, configured by `:cloak_repo` / `:cloak_schemas` or `-r` / `-s`; it pages by keyset in fixed batches, re-encrypts row-by-row under `SELECT ... FOR UPDATE` inside `Task.async_stream`, and its docs warn about connection-pool exhaustion | Read from source and moduledoc | 6 |
| C7 | Cloak's `Ecto.Type` layer has no per-user or per-tenant key model - its README says so directly - so a migrating host's legacy rows are under one key | README | 5 |
| C8 | `Cloak.Ciphers.AES.GCM` is AEAD with a 16-byte auth tag; `Cloak.Ciphers.AES.CTR` is an unauthenticated stream cipher whose decrypt cannot fail on wrong content | Read from source | 3 |
| C9 | The cloak migrator identifies its own fields by testing for an exported `__cloak__/0` on the type module | Read from source | 1, 7 |
| C10 | A cloak type declared with `closure: true` returns a zero-arity function from `load/1` rather than the plaintext, deferring the decryption until it is called | Read from source | 2 |

C2 and C8 are the load-bearing pair, and they interact. C2 is what makes the
probe in ADR-0002 decision 5 decisive; C8 is the case where C2 holds
*mechanically* (a tag mismatch does return `:error`) while being useless
*semantically* (matching bytes that are corrupt return a value). Decision 3 is
the whole response, and the mitigation if some other legacy type turns out to
behave the same way needs nothing from this package: the host writes a
`Source` implementation that validates before returning, which decision 2's
third row already allows.

Two further caveats are recorded rather than smoothed over, because a future
reader will otherwise take the table as more settled than it is. Whether
`cloak_ecto`'s migrator persists a cursor *between invocations* could not be
established from its documentation - the resumability claim in C6 is about the
pagination being keyset-shaped, not about a saved checkpoint, and this
record's decision 6 comparison is careful not to claim otherwise. And the
exact flag set of `mix cloak.migrate.ecto` beyond `-r` / `-s` was not
established; the comparison table cites only what its moduledoc shows.

## The contract as typespecs

Everything here extends ADR-0002's typespecs; nothing in those is restated or
changed.

```elixir
defmodule Encryptor.Ecto.Migrator.Source.EctoType do
  @moduledoc """
  Adapts a module that already reads the pre-migration bytes - an `Ecto.Type`,
  an `Ecto.ParameterizedType`, or anything exporting their load callbacks -
  to the `Encryptor.Ecto.Migrator.Source` behaviour.
  """

  @behaviour Encryptor.Ecto.Migrator.Source

  @type arity_shape :: :ecto_type | :parameterized_type

  @spec shape(module()) :: {:ok, arity_shape()} | {:error, :not_a_type}

  @impl true
  @spec load(binary(), params :: map()) :: {:ok, term()} | {:error, term()}
end

defmodule Encryptor.Ecto.Migrator.Source.Plaintext do
  @behaviour Encryptor.Ecto.Migrator.Source
end
```

Decision 3's additions to ADR-0002's field spec and report:

```elixir
# Encryptor.Ecto.Migration.field_spec/0 gains two keys.
@type field_spec :: [
        from: module(),
        to: module(),
        into: atom() | nil,
        source_authenticated: boolean(),
        validate: (term() -> boolean()) | nil
      ]

# Encryptor.Ecto.Migrator.Report.class/0 gains one member.
@type class ::
        :null
        | :already_target
        | :migratable
        | :migratable_unverified
        | :undecryptable
```

The telemetry event of decision 5, whose metadata set is closed:

```elixir
:telemetry.execute(
  [:encryptor_ecto, :legacy_load],
  %{count: 1},
  %{table: "accounts", column: "tax_id"}
)
```

The mix task grammar of decision 6 has no typespec; its contract is the flag
table and the exit codes, both of which belong in the tasks' `@moduledoc`.

## Worked example: a card-processing host leaves cloak_ecto

A multi-tenant payment host with `accounts`, `budgets`, and `transactions`.
The encrypted columns are the cardholder tax identifier and the free-text note
on a transaction, and there is one exact-match lookup: find an account by
contact email. Before, on `cloak_ecto`:

```elixir
defmodule MyApp.Cloak.Encrypted.Binary do
  use Cloak.Ecto.Binary, vault: MyApp.CloakVault
end

defmodule MyApp.Payments.Account do
  use Ecto.Schema

  schema "accounts" do
    field :tenant_id, :binary_id
    field :tax_id, MyApp.Cloak.Encrypted.Binary
    field :contact_email, MyApp.Cloak.Encrypted.String
    # cloak's own answer to lookups: unsalted, unkeyed, recoverable from a dump
    field :contact_email_hash, Cloak.Ecto.SHA256
  end
end
```

Step 3 of the runbook. The type modules change; the schema does not:

```elixir
defmodule MyApp.Encrypted.Binary do
  use Encryptor.Ecto.Binary,
    vault: MyApp.Vault,
    legacy: MyApp.Cloak.Encrypted.Binary
end

defmodule MyApp.Encrypted.String do
  use Encryptor.Ecto.String,
    vault: MyApp.Vault,
    legacy: MyApp.Cloak.Encrypted.String
end
```

The plan, deleted at step 8. This host's vault is on AES.CTR, so the fields
declare decision 3's acknowledgement and borrow the hash column as a
validator (decision 3c):

```elixir
defmodule MyApp.Encryption.CloakMigration do
  use Encryptor.Ecto.Migration, repo: MyApp.Repo

  rewrite MyApp.Payments.Account do
    tenant_from :tenant_id

    field :tax_id,
      from: MyApp.Cloak.Encrypted.Binary,
      to: MyApp.Encrypted.Binary,
      source_authenticated: false,
      validate: &MyApp.Encryption.Checks.tax_id?/1

    field :contact_email,
      from: MyApp.Cloak.Encrypted.String,
      to: MyApp.Encrypted.String,
      source_authenticated: false,
      validate: &MyApp.Encryption.Checks.email_matches_stored_hash?/1
  end
end
```

Step 4, the rehearsal, from a release:

```
$ bin/my_app eval 'Encryptor.Ecto.Migrator.run(MyApp.Encryption.CloakMigration, mode: :dry_run)'
accounts.tax_id         null 412  already_target 1,908  migratable_unverified 2,204,551  undecryptable 0
accounts.contact_email  null 0    already_target 1,908  migratable_unverified 2,204,960  undecryptable 3
dry run: no rows written
$ echo $?
1
```

Three undecryptable rows and a non-zero exit. That is the dry run doing its
job: the operator investigates before writing anything, finds three accounts
belonging to a tenant offboarded last year, and adds `except_tenants:` to the
run rather than reaching for `on_error: :continue` (ADR-0002 decision 11).
`already_target` is non-zero because step 3 has been live for a day and
ordinary traffic has been migrating rows on its own. The counts say
`migratable_unverified`, not `migratable`, for the whole pass - and they will
keep saying it, because no authentication tag ever confirmed those rows.

Step 5, the pass, against live traffic, with the application serving:

```
$ bin/my_app eval 'Encryptor.Ecto.Migrator.run(MyApp.Encryption.CloakMigration, mode: :write, except_tenants: ["tnt_offboarded"])'
accounts.tax_id         written 2,204,549  concurrent 37  failures 2  cursor 2,206,871
accounts.contact_email  written 2,204,960  concurrent 41  failures 0  cursor 2,206,871
```

Two failures on `tax_id`, from `validate:` rejecting a loaded value that was
not nine digits. Under the default `on_error: :halt` the pass stopped there
and reported both primary keys. Those two rows are the entire reason decision
3 exists: an AEAD source would have called them `:undecryptable` on its own,
a CTR source called them plaintext, and only the host's own knowledge of its
own data caught them.

Step 6, the acceptance test, and the signal that step 8 is due:

```
$ bin/my_app eval 'Encryptor.Ecto.Migrator.verify(MyApp.Encryption.CloakMigration, sample: :all)'
accounts.tax_id         already_target 2,204,551  null 412  other 0
accounts.contact_email  already_target 2,204,960  null 0    other 0
ok
$ echo $?
0
```

Step 7, the lookup. `contact_email_hash` is replaced, not supplemented: a new
`contact_email_index` column, a per-tenant keyed index (ADR-0003 decision 3a),
backfilled in tenant scope - and the `Cloak.Ecto.SHA256` column dropped in the
same migration that stops writing it, now that decision 3c has finished using
it.

Step 8, one commit: `legacy:` gone from both type modules, `cloak_ecto` gone
from `mix.exs`, `MyApp.Encryption.CloakMigration` deleted. The
`[:encryptor_ecto, :legacy_load]` counter has been flat at zero since the pass
finished, which is the evidence that the commit is safe.

## Open questions

Recorded because they are not this record's to settle, or not yet settleable.

**Q1. Whether the migrator should backfill blind indexes in the same pass.**
Decision 9 separates them, and the argument against combining is real
(attributability, and the migrator's deliberate position below the schema
layer). The argument *for* is also real and gets stronger with table size: the
migrator already holds the plaintext in its hand for every row it rewrites, so
a combined pass costs one decrypt where two passes cost two, over the largest
tables a host has. A field-spec option (`index: :contact_email_index`) would
express it. Deferred rather than declined: it is additive, and doing it now
would couple ADR-0002's engine to ADR-0003's helper before either exists.
Owner: this repo, after both are implemented.

**Q2. Whether `source_authenticated: false` should be inferred rather than
declared.** Decision 3a makes it a hand-written acknowledgement, on the theory
that the host knows its own cipher and should say so. The alternative - infer
it, by having `Source` report whether the underlying scheme authenticates -
is not available for an `Ecto.Type`-shaped source, which exports no such fact,
and adding a callback for it would be adding a contract the legacy modules
cannot implement. So the declaration stands, and the cost is that a host on
AES.CTR which declares nothing gets ordinary `:migratable` counts and a false
sense of verification. Whether a documentation warning is enough, or whether
the plan macro should require an explicit `source_authenticated: true` on
every field so that silence is never the unsafe answer, is open. Owner: this
repo, before implementation.

**Q3. What the migrator does with a schema whose primary key it cannot order.**
ADR-0002's Q6 already holds this open for the founding implementation. It
lands on this record specifically because a host arriving from cloak arrives
with whatever primary keys it already has, and a migration tool that refuses a
composite-key table is refusing a host, not a feature. Whether the answer is a
restriction with a clear error, an `order_by:` escape hatch in the plan, or
something else, is ADR-0002's Q6 to answer. Owner: this repo, before
implementation.

**Q4. Whether the `legacy_load` telemetry event is the right shape for the
window-end signal.** A counter that has read zero for a retention period is
evidence about *traffic*, not about *rows*: a table with a cold partition
nobody reads would report zero while still holding legacy bytes. `verify`
covers that and is the primary signal (decision 5), so the event is a
convenience rather than a proof - but a host that treats it as proof would be
wrong in a way that is quiet. Whether the answer is documentation, a different
name, or dropping the event, is open. Owner: this repo, at implementation.

**Q5. Whether the mixed window needs an explicit expiry.** Decision 5 detects
the window's end but does not bound it: nothing stops a host from running with
`legacy:` set for two years. A compile-time `legacy_until:` date that warns
after it passes was considered and is not proposed, because a warning in a
host's build for a migration the host has reason to defer trains them to
ignore warnings. Left open in case a better mechanism appears. Owner: this
repo.

**Q6. Whether `gen.plan` can find encrypted fields without loading the host's
application.** Reading `__schema__(:type, field)` requires the schema modules
compiled and loaded, which a Mix task in the host's project has and a release
command does not. `gen.plan` is therefore the one member of the family with no
release equivalent - which is fine, since it writes source into a working
tree. Stated rather than decided, because it is the one place decision 6's
"the library function is the real interface" does not hold, and a later reader
should find that acknowledged rather than discover it.

## Consequences

**The engine never learns about cloak, so cloak's releases are not this
package's problem.** The compatibility surface is the `Ecto.Type` behaviour,
which is Ecto's and stable, and the module implementing it is the host's. When
`cloak_ecto` changes, this package's test suite is unaffected because it never
referenced it; what may need a line is the guide.

**A migration from an unauthenticated cipher is honestly labelled as
unverified, forever.** Decision 3 does not make a CTR migration safe - nothing
can, because the information required was never stored. What it does is refuse
to let the report claim otherwise: `migratable_unverified` appears in the dry
run, in the write pass, and in `verify`, and the operator who ran it can say
exactly what was and was not checked. That is a worse-looking report and a
better-informed operator, which is the trade this record wants.

**Hosts on AES.CTR must write a validator or accept a read-only rehearsal.**
Decision 3a refuses `--mode write` without one. Some hosts will find this
annoying and a few will find it impossible - a free-text note with no
structure has no validator worth writing. Those hosts run with a `validate:`
that returns `true` and a comment saying why, which is a decision recorded in
their own repository rather than a default this package chose for them.

**The mixed window is the most dangerous state in the whole design, and it is
now the state with the most documentation.** A host in the window is running
two key models over one column, with the weaker one still authoritative for
most rows. Decision 5 makes that explicit, decision 8 makes closing it a
numbered step, and the telemetry event makes it observable - but the window is
still a state a host can sit in indefinitely, and Q5 records that nothing
prevents it.

**The dry run is load-bearing and exits non-zero when it finds something.**
That is a deliberate departure from the reflex that a read-only rehearsal
"succeeded" because it ran. It means CI or a deploy script can gate on it, and
it means an operator who runs it and glances at the exit code gets the same
answer as one who reads the table.

**`gen.plan` produces a file that does not compile, on purpose.** This will
read as a bug to somebody, at least once, and the generated file therefore
carries a comment saying why. The alternative - a plan that compiles with a
guessed tenant column - fails at row one in the best case and re-encrypts
2.2 million rows under one tenant's key in the worst.

**Four tasks, and the family is closed.** Every capability is reachable from
`Encryptor.Ecto.Migrator`, so a host that wants a census task, an Oban-driven
pass, or an approval-gated admin action builds it from the library function.
This package's task list still contains no verb that operates on a key
(ADR-0002 decision 9), and now also contains no verb that operates on a
schema.

**A tutorial is missing on purpose, and the docs index says so.** Otherwise it
gets written, by someone reasonably observing that the documentation set has a
hole in it.
