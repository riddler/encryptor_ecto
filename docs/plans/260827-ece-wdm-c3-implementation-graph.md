# The C3 implementation graph

Bead: `ece-wdm`. Date: 2026-08-27. Status: design only - no implementation
work is authorized against any bead below in campaign 008.

This document turns four ADRs into an ordered, dependency-linked set of work
items. It is a map of decisions to beads, not a plan for any one of them: each
bead carries its own scope in its description, and this document exists so that
a reader can see which ADR decision each bead discharges, what has to be true
before it can start, and where the graph is still waiting on something outside
this repository.

## The records this graph is built from

| Record | Status | What it fixes |
|---|---|---|
| ADR-0001 | accepted 2026-08-27, with five acceptance amendments | The `cloak_ecto`-shaped vault-backed types, the closed option set, the frozen declared context, tenant resolution from an explicit process scope, and the raising failure model |
| ADR-0002 | accepted 2026-08-27 | The migrator: a plan-driven, probe-first, compare-and-swap row rewriter that runs against live traffic, plus verification |
| ADR-0003 | accepted 2026-08-27, with one amendment | Keyed blind indexes, per-tenant by default, equality only |
| ADR-0004 | **proposed** | Adoption: the `Source` seam, the unauthenticated-source acknowledgement, the `legacy:` window, the task family, the runbook, and the documentation set |

ADR-0004 is proposed, not accepted. Every bead it implies is filed and
sequenced here, because the graph is more useful whole than partial, but none
of them may be started before the record is accepted. The beads say so where
it matters; this line is the general one.

Two of the graph's roots are cross-repository and are named here rather than
buried in a description:

- `ece-55n` (the Binary type) needs the `encryptor` vault core, `enc-p5p`, on a
  pushed SHA, per the linkage recipe already recorded on `ece-1o7`.
- `ece-d72` (blind-index key derivation) needs the `encryptor` HKDF surface,
  `enc-j4h`. ADR-0003's assumptions A8 and A10-A13 are design obligations on
  that surface rather than facts about it: derivation without exporting the
  input key material, a per-deployment salt distinct from any encryption salt,
  Argon2id parameters readable as an opaque set, and derived key material held
  in a form that never reaches `Inspect` output.

## The shape of the graph

Four arms, and they are genuinely different jobs rather than four slices of one.

**The types arm** is the only one with no predecessor inside this repository,
and everything else waits on it. `ece-1o7` was one bead covering all of
ADR-0001; it is now the arm's epic, depending on its five children, so it
closes when the arm is done and every bead hanging off it stays correctly
blocked until then.

**The blind-index arm** hangs off the types arm because the index derivation
reads the same `Ecto.ParameterizedType` params - table and column - that
ADR-0001 decision 4 freezes, and asks the same tenant strategy the type was
declared with. `ece-l8v` was decomposed the same way `ece-1o7` was.

**The migrator arm** hangs off the types arm too, because the engine calls the
`to` type's `dump/3` and the `from` side's load directly, with params it
constructs. It also carries the graph's only two decision-shaped beads and its
only build-shaped one.

**The documentation arm** is ADR-0004 decision 10's three pages, and it trails
the surfaces it documents on purpose: a how-to that is written before the flag
table is fixed is a how-to that drifts from it.

## Types: ADR-0001

Epic: `ece-1o7`, which now depends on `ece-55n`, `ece-rvs`, `ece-gr3`,
`ece-9p0`, `ece-tgx`.

| Bead | Discharges | Depends on |
|---|---|---|
| `ece-1br` Tenant and the TenantContext behaviour | d5a, d5b, d5f, and both typespec blocks | - |
| `ece-ld8` The exception family | d6, acceptance amendment 2 | - |
| `ece-55n` Binary and the ParameterizedType callbacks | d1 (Binary), d2, d3, d6, d7, d9, d11, acceptance amendment 1 | `ece-1br`, `ece-ld8` |
| `ece-rvs` The declared-context freeze and its uniqueness check | d4, acceptance amendment 5 | `ece-55n` |
| `ece-gr3` String and Map | d1 (the other two), d8 | `ece-55n` |
| `ece-9p0` `tenant: :none` and the `:single`-vault rule | d5e, acceptance amendment 3 | `ece-55n` |
| `ece-tgx` The test-support scope helper | the Consequences' shipped-helper commitment | `ece-1br` |
| `ece-rh0` The remaining wrapper types | d1's explicit deferral | `ece-gr3` (P3, additive) |

Three notes on why the splits fall where they do.

`ece-1br` and `ece-ld8` are separated from `ece-55n` because neither touches
the vault. They are the only nodes in the whole graph that can be built and
tested with nothing from `encryptor` in the tree, which makes them the right
place for the arm to start while the cross-repo dependency settles.

`ece-rvs` is separate from `ece-55n` because its second half is a distinct
mechanism rather than a detail of `init/1`. Freezing the derived values is a
few lines; checking that no two declarations share a table/column pair is a
cross-module question, and a compile-time accumulator cannot see two modules
that never reference each other. The likely shape is a start-time check over
loaded modules, and deciding that is work rather than typing. The property it
protects is the one the encryption context exists for: two fields sharing a
declared pair are silently mutually substitutable.

`ece-9p0` is separate because the d5e rule as amended is a check against the
vault's *profile*, not against this package's options. A `:none` field must
name a `:single`-profile vault, because a `:tenant`-profile vault has the
tenant pair in its required set and refuses an operation without it. Whether
the check can run at compile time depends on whether the profile is resolvable
from the vault module alone, which is a question about `encryptor`.

What is deliberately not in this arm: the `legacy:` load path. It is an option
on the type, but it exists only for the migration window, its trigger
conditions are ADR-0004 decision 4's, and its telemetry event is ADR-0004
decision 5's. It is `ece-e8k`, hanging off `ece-1o7`, and it is gated on
ADR-0004 being accepted.

## Blind index: ADR-0003

Epic: `ece-l8v`, which now depends on `ece-d72`, `ece-7tk`, `ece-8cn`,
`ece-6a6`.

| Bead | Discharges | Depends on |
|---|---|---|
| `ece-d72` Key derivation | d2, d3a | `ece-1o7` |
| `ece-7tk` `blind_index/3` and the normalizers | d4, d3c's compile errors, d6's declaration half | `ece-d72` |
| `ece-8cn` `put_index/3`, `where_eq/3`, `where_eq_candidates/3`, `compute/3` | d5, d8 | `ece-7tk` |
| `ece-6a6` `:bits`, `:slow`, `:version` | d6's option half, d7 | `ece-8cn` |
| `ece-q0s` The option reference and the security-properties table | the Consequences' deliverable claim | `ece-l8v` |
| `ece-xk6` Replacing legacy lookup columns (already filed) | ADR-0004 d9 | `ece-l8v` |

This arm is a chain rather than a fan, because each node genuinely needs the
one before it: the declaration macro needs the derivation it will call, the
helpers need the declaration they read their configuration from, and the width
and slow-hash options change what the helpers do rather than adding a surface
beside them.

The arm's open questions are placed where they bite rather than left loose.
ADR-0003 Q5 (`:digits` and international phone numbers, which matters because
decision 9 supports unique constraints over the index) is carried on `ece-7tk`.
ADR-0003 Q3 (a query is data and can outlive the process that built it, so a
query struct carries an invisible tenant-specific constant) is carried on
`ece-8cn`.

**`ece-d72` has a blocking text defect ahead of it**, filed as `ece-0rn` item
2. As accepted, index keys are derived subkeys under the upstream derivation
label, while decision 2 states its own literal domain-separation prefix.
Whether the two compose or the amendment supersedes the prefix is not written
down, and that prefix is the structural half of the "an index key is never an
encryption key" guarantee. This is a cryptographic decision, so per this
repository's own rule it is an ADR answer and not an implementation one.

## Migrator: ADR-0002 and ADR-0004

| Bead | Discharges | Depends on |
|---|---|---|
| `ece-4ib` Keyset ordering for non-orderable primary keys | ADR-0002 Q6, ADR-0004 Q3 | - |
| `ece-l6t` Plan scope for multi-repo hosts, and the gen.migration DDL disclaimer | ADR-0002 Q4, Q5 | - |
| `ece-cuo` A Postgres service in CI | `ece-b25`'s own precondition | - |
| `ece-90m` `Source` and the `EctoType` adapter (already filed) | ADR-0004 d2 | `ece-1o7` |
| `ece-4mg` The unauthenticated-source acknowledgement (already filed) | ADR-0004 d3 | `ece-90m` |
| `ece-vqe` The plan DSL and its compile-time checks | ADR-0002 d2, ADR-0004 d2's plan half | `ece-90m`, `ece-l6t` |
| `ece-b25` The engine | ADR-0002 d3, d4, d5, d6, d7, d11, d12 | `ece-1o7`, `ece-90m`, `ece-vqe`, `ece-4ib`, `ece-cuo` |
| `ece-7fr` `verify/2` and the SQL census | ADR-0002 d10 | `ece-b25` |
| `ece-5qb` The mix task family (already filed) | ADR-0004 d6 | `ece-b25`, `ece-l6t` |
| `ece-6ba` `gen.plan` (already filed) | ADR-0004 d7 | `ece-5qb` |
| `ece-cxk` Folding index backfill into the rewrite pass | ADR-0004 Q1 | `ece-l8v`, `ece-b25` (P3, deferred) |

`ece-b25` was titled "Implement the re-wrap/rotation mix task". That title
named a thing ADR-0002 decision 9 refuses on the record - re-wrap touches the
key store, the key store is the vault's, and this package's task list contains
no verb that operates on a key. Its description was already about the migrator,
so the title was the only stale part and it has been corrected. The same phrase
survives in this repository's `CLAUDE.md`, which is `ece-0rn` item 4.

Three beads sit ahead of the engine deliberately.

`ece-4ib` and `ece-l6t` are decisions, not implementations, and they sit ahead
of the surfaces they shape: whether the plan grows an `order_by:` escape hatch
or a documented restriction changes the plan format, and whether the checkpoint
is a generated migration or a file changes what `gen.migration` is for.
Answering them after the engine exists means changing the engine.

Three of the four questions carry an explicit owner line assigning them to this
repository "before implementation" - ADR-0002 Q5 and Q6, and ADR-0004 Q3, which
restates Q6. ADR-0002 Q4 carries no owner and is recorded only as "Not
settled"; it is folded into `ece-l6t` because `ece-5qb` ships `gen.migration`
either way and somebody has to have decided by then.

`ece-cuo` is a build item and it lands alone. `ece-b25`'s own description asked
for the CI service; splitting it out keeps a workflow-file change off a branch
that also moves `lib/`. It is a blocker rather than a follow-up because the
properties the engine promises are not expressible against a mock repo:
compare-and-swap against a concurrent writer, keyset resume across a killed
process, and the probe correctly classifying an already-migrated row all need
real rows.

`ece-cxk` is deferred rather than declined, and its two dependencies are the
representation of that: ADR-0004 Q1 says explicitly that combining the passes
before both engines exist would couple them before either is built.

## Documentation: ADR-0004 decision 10

The record fixes a three-page set and refuses a tutorial. The refusal is
carried forward here so that nobody later fills the hole by reasonably
observing that the set has one.

| Page | Type | Bead |
|---|---|---|
| `docs/guides/migrate-from-cloak.md` | How-to | `ece-k5i` (behind `ece-5qb`) |
| `docs/explanation/moving-off-cloak.md` | Explanation | `ece-22g` (behind `ece-1o7`) |
| The tasks' `@moduledoc`s | Reference | inside `ece-5qb` |
| A tutorial | - | **deliberately absent** |

The reason for the refusal, restated because it is the part that gets lost: a
tutorial's promise is a safe place to practice, and the practice article for a
destructive migration would either operate on a host's real data - the exact
thing it is meant to teach care with - or on a toy that omits live traffic,
tenant scope and undecryptable rows. The dry run *is* the rehearsal, it happens
against the host's own data, and it is step 4 of the how-to. The docs index
should say the tutorial is missing on purpose; `ece-22g` carries that line.

One page is outside decision 10's set and is still a deliverable: `ece-q0s`,
the blind-index option reference and security-properties table. ADR-0003's
Consequences call that table "the deliverable a host reviews before adding an
index, not after", which makes it a shipped artifact rather than an appendix.

The README is not in this table because it is not part of the set. It is
brought current with the accepted ADR surface on this bead, as a design-phase
statement of what is decided and what is not.

## Suggested order

The dependency edges are the contract; this is the reading of them.

| Wave | Beads | Why here |
|---|---|---|
| 0 | `ece-4ib`, `ece-l6t`, `ece-cuo`, `ece-1br`, `ece-ld8` | Everything with no blocker. The two decision beads and the CI service can run against a repository with no `lib/` at all, and the two type roots need nothing from `encryptor` |
| 1 | `ece-55n` | The cross-repo node. Nothing else in the arm moves until it does |
| 2 | `ece-rvs`, `ece-gr3`, `ece-9p0`, `ece-tgx` | Fan out from Binary; independent of each other |
| 3 | `ece-1o7` closes; then `ece-90m`, `ece-e8k`, `ece-22g`, `ece-d72` | The epic closing is what unblocks the other three arms |
| 4 | `ece-4mg`, `ece-vqe`, `ece-7tk` | The migrator and index chains resume |
| 5 | `ece-b25`, `ece-8cn` | The engine, and the index helpers |
| 6 | `ece-7fr`, `ece-5qb`, `ece-6a6` | Verification, the task family, the index options |
| 7 | `ece-l8v` closes; then `ece-6ba`, `ece-k5i`, `ece-q0s`, `ece-xk6` | The docs and the generator, once the surfaces they describe are fixed |
| 8 | `ece-rh0`, `ece-cxk` | Additive and deferred; neither blocks anything |

Waves 3 and 7 are the two places the graph narrows to a single point, and both
are epics closing rather than work items finishing. That is the intended shape:
an epic that depends on its children is a gate, and both of these gates guard
arms that would otherwise start against a half-built surface.

## What this graph does not cover

- **`ece-aia`**, the Hex name reservation, is a publish-shaped operation and is
  the operator's. It is not sequenced here.
- **`ece-67g`** and **`ece-0rn`** are operator-only text fixes. `ece-0rn` item 2
  is the one with a downstream consequence: `ece-d72` should not start before
  it is answered.
- **ADR-0002's R1 and R4** - re-wrapping the key-encrypting key, and
  crypto-shredding a tenant - are the vault's, on the record, and no bead here
  touches them. The seam decision 9 draws is: if an operation would still be
  needed by a host that stores its ciphertext somewhere other than Ecto, it is
  not this package's.
- **Concurrency in the migrator** is deferred by ADR-0002 decision 12 and has
  no bead. Keyset ranges partition cleanly, so adding it later is additive and
  needs no change to the plan format or the checkpoint schema.
- **The plaintext-adoption expand/backfill/contract sequence** is a documented
  runbook rather than a mechanism; `Source.Plaintext` ships inside `ece-90m`
  and the DDL and cutover are the host's.
