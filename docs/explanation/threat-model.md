# The threat model of the Ecto layer: what it adds, what it leaks, and how we know

This page is about the surface this package adds above the vault, and what
that surface gives an attacker: the blind index columns beside an encrypted
one, the tables this package reads and writes (the key store first), and the
migrator, the one component that decrypts every row it visits. For each claim
it names the test or the decision record that holds the claim in place, and
where nothing does, it says so. Nothing here needs to be run.

Everything below the Ecto type is the vault's and is not restated here: the
key hierarchy, the message format, AES-GCM and its limits, the key providers,
the engine underneath and its known defects, and what a database reader learns
from a ciphertext column. That is
[encryptor's threat model](https://github.com/riddler/encryptor/blob/main/docs/explanation/threat-model.md),
and this page assumes it. Read its "Someone who can read the database" and
"Someone holding a backup" sections first; this page extends both to the
columns and tables this package puts in the same database.

## What this package adds to the database

An encrypted field stores the vault's bytes verbatim, with no envelope, prefix
or magic bytes of this package's own
([ADR-0001](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0001-vault-backed-ecto-types.md)
decision 11), so a ciphertext column holds exactly what encryptor's page
describes. One thing about it is this package's choice rather than the
vault's: the encryption context a field writes. It is the declared `"table"`
and `"column"`, the vault's static pairs, the scope reference on a scoped
field, and any pairs the field's `:context` option adds. Every one of them
travels in the clear in every message, so a pair a host adds is public to
anyone holding the dump
([How to bind extra identifiers](../guides/bind-extra-context.md) says what
belongs there for that reason).

Beside the ciphertext columns, this package can put four more kinds of thing
in a host's database:

- **Blind index columns**, one per declared index, holding a keyed fingerprint
  of the normalized plaintext.
- **The key store**, the wrapped-key table `Encryptor.Ecto.KeyStore` reads.
- **The suspension table**, where `Encryptor.Ecto.SuspensionStore` keeps the
  scopes an operator suspended.
- **The migrator's checkpoint table**, where a pass records how far it got.

Each of them is generated migration source the host reads, commits and runs;
this package issues no DDL
([ADR-0002](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0002-migrator.md)
decision 9). Each is also something a database dump carries.

## What a dump reveals

A copy of the database, from a replica, a backup or an injection, with no key
material. Ciphertext columns yield what encryptor's page says they yield: no
plaintext, each value's length and its context. The rest, table by table:

**Blind index columns** yield equality structure: which rows share a value,
and how many distinct values there are, within each scope for a
`derive: :per_scope` index and across the whole table for a `derive: :global`
one. They do not let a reader confirm that a guessed plaintext is present,
because the candidate value cannot be computed without the index key. The full
table, row by row, is
[the security properties of a blind index](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.BlindIndex.html#module-security-properties),
at the declaration a host writes; this page does not restate it. Read its
frequency-analysis paragraph before indexing anything: an index over a
low-cardinality column is readable off its counts with no key at all.

**Key-store rows** yield the wrappings, which are encrypted, and the
identifiers around them, which are not. The next section takes the columns one
by one.

**Suspension rows** yield the selector of every suspended scope, as the host
wrote it. This is the one table this package writes that stores a raw scope
identifier for every scope it concerns (a checkpoint row stores only those a
migration pass was filtered by, below): the suspension store has to answer selectors, and a keyed
reference cannot be turned back into one (`Encryptor.Ecto.SuspensionStore`'s
"The table"). A dump therefore tells its reader which scopes an operator has
suspended.

**Checkpoint rows** yield the plan, schema and field of each migration pass,
the primary key it last committed, and its classification counts: how many
rows were migrated, skipped, or could not be read. Beside the counts, each row
also records the run that wrote it and whether that pass reached the end of its
rows: the raw scope identifiers it was given in `only_scopes:` or
`except_scopes:`, and the wrapping key name a rotation's `writing_key:` named
(a name, never key material), so a dump tells its reader which scopes were
migrated or rotated separately and under which key name. That is a
description of the migration, not of any value
([`Encryptor.Ecto.Migrator.Checkpoint`](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.Migrator.Checkpoint.html),
"Its shape" and "The key carries the run, and a resume continues only its
own").

**A plaintext column being adopted** yields its plaintext. A host moving a
column that was never encrypted onto this package backfills a new binary
column beside it, and until the contract step drops the old column, the old
column still holds every value in the clear
(`Encryptor.Ecto.Migrator.Source.Plaintext`). The security improvement lands
when the column is dropped, not when the backfill finishes.

**A cloak-format row inside the mixed window** yields what the old scheme
leaves exposed. While a field declares `legacy:`, a row the migrator has not
rewritten is still in the old format, under the old key and with no
encryption context. The same field also loads legacy-format bytes that a
writer puts into a row the migrator already rewrote, because the fallback
answers any bytes the vault refuses and those bytes carry no context; that
holds until `legacy:` is dropped, not until the pass finishes. [What changes
when you move off
cloak_ecto](moving-off-cloak.md#the-mixed-window-is-a-downgrade-until-legacy-is-dropped)
explains the downgrade and why dropping `legacy:` is what closes it.

Pinned by: "load while legacy: is declared, and are counted as a legacy read"
and "raise once legacy: is dropped, while the migrated row still loads"
([`test/encryptor/ecto/legacy_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/legacy_test.exs)).

A reader who can also write gains little the vault does not already refuse. A
value moved to another column, or to another scope's row, fails to decrypt
rather than decrypting in the wrong place, because the column and the scope
reference are both in the context the message is bound to. Nothing in the
context names the row, though: two rows of one column under one scope can
have their bytes swapped, and each then loads as the other's value.

Pinned by: "binds the column, so one column's bytes do not load as another's"
and "fails authentication rather than reading across the boundary"
([`test/encryptor/ecto/binary_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/binary_test.exs));
the repository-backed scope test in
[`test/encryptor/ecto/types_repo_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/types_repo_test.exs);
"both load, each as the other's value" for the swap
([`test/encryptor/ecto/binary_repo_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/binary_repo_test.exs));
"a ciphertext moved across partitions fails authentication"
([`test/encryptor/ecto/key_store_repo_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/key_store_repo_test.exs));
"a different table or column derives different bytes" and "a different scope
derives different bytes" for the index columns
([`test/encryptor/ecto/blind_index/derivation_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/blind_index/derivation_test.exs)).

## What a dump and one scope's index key reveal

The blind index's security properties answer this one too, and the answer is
bounded by the derivation: a `derive: :per_scope` index key opens that scope's
index columns to guessing and nothing about any other scope, while a
`derive: :global` key opens every scope's at once. Over a low-entropy column
it is full recovery of the guessable space, at HMAC speed unless the index
declares `slow: true`.

The caveat on that page is the one worth carrying away. An index key is not a
narrower capability than decryption today: index keys are derived from the
same scope key material the encryption keys come from, so a component that can
compute an index value holds a vault that can also read the column. The
separation that does hold is structural. An index key is never an encryption
key, because the derivation nests the index tree under its own label, and two
deployments provisioned from the same key material derive unrelated index keys,
because the vault's per-deployment salt sits under the whole construction. A
restored backup or a cloned staging database cannot be joined against
production on an index column.

Pinned by: "two deployments sharing key material derive unrelated keys", "the
exported bytes are never the intermediate purpose key" and "a vault with no
:derivation_salt refuses to derive"
([`test/encryptor/ecto/blind_index/derivation_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/blind_index/derivation_test.exs));
"the value is HMAC-SHA256 of the normalized plaintext under the index key" and
"the value is the HMAC over slow_hash(normalized, index_salt, params)"
([`test/encryptor/ecto/blind_index/value_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/blind_index/value_test.exs));
[ADR-0003](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0003-blind-index.md),
its "Security properties" section and Amendment C.

## What a dump retained after a shred reveals

A shred is a `DELETE` of the scope's key-store rows, through
`Encryptor.Ecto.KeyStore.shred/3`: every version for a whole-scope shred, one
version for a single-version one. The wrapping is the only copy of the key, so
deleting it destroys the key, and nothing here soft-deletes
([ADR-0007](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0007-suspension-store-and-shred.md)
decision 3). After it, a read through the vault fails: `{:unknown_key,
selector}` once the scope has no row, and `:decrypt_failed` for a value
written under a deleted version.

What a dump taken *after* the shred, or kept from before it, still shows:

- **The ciphertext**, which is unreadable once no copy of the wrapping is
  left, and readable to whoever holds an older copy and the root. A dump taken
  before the shred is such a copy. That is encryptor's "Someone holding a
  backup", and its rule stands here unchanged: a shred makes data unreadable
  wherever the destroyed wrapping was the last copy.
- **The blind index columns.** A `derive: :per_scope` column becomes noise,
  because no candidate value can be computed to compare against it. A
  `derive: :global` column keeps its equality structure, and guessable values
  stay recoverable to anyone holding the global index key: the last row of the
  [blind index table](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.BlindIndex.html#module-security-properties),
  and the reason `:global` has to be written out loud.
- **Fields declared `scope: :none`**, which are not under the scope's key at
  all and do not participate in its shred
  ([ADR-0001](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0001-vault-backed-ecto-types.md)
  decision 5e; [the field that opts out](moving-off-cloak.md#crypto-shredding-and-the-field-that-opts-out)).
- **A suspension row**, if the scope was suspended before it was shredded and
  never reinstated: the selector, in the clear. Nothing in the shred deletes
  it, because the shred's delete is scoped to the key store's table.
- **The scope reference** wherever it still appears: in every surviving
  message header and, for a scope shredded one version at a time, in its
  remaining rows. It identifies the scope to no one without the reference
  subkey.

Two limits of the shred itself are documented at `shred/3` and belong in a
threat model. A version provisioned concurrently with a whole-scope shred is
deleted if it commits before the shred's second look, and survives as the
scope's newest key if it commits after; the host closes that window by
stopping provisioning for the scope first and confirming afterwards that no
row remains. And the vault's materials cache can serve a deleted version for
up to its `max_age` after the delete, a little longer for a decrypt that was in
flight at the commit; `drain: :wait` waits that bound out, and a host that
needs a hard bound restarts its vaults.

Pinned by: "deletes every version, and a read then fails unknown_key",
"leaves every other scope's rows alone", "deletes one version; its values fail
decrypt_failed and the rest still serve", "drain: :wait returns only after the
cache's max_age, and the read then fails" and "after P3 a warm cache does not
serve the scope, even with the drain skipped"
([`test/encryptor/ecto/key_store_shred_repo_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/key_store_shred_repo_test.exs));
the late-version re-check in
[`test/encryptor/ecto/key_store_shred_recheck_repo_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/key_store_shred_recheck_repo_test.exs).
No test shreds a scope and then computes a `derive: :per_scope` index value
against the retained column: the "noise" claim rests on the derivation running
through the vault under the scope's key material, which the tests above show
is gone.

## The key store's columns, and what each exposes

The table is the six fields of encryptor's `Encryptor.Envelope.WrappedKey`
plus two of this package's, a surrogate id and timestamps
([`Encryptor.Ecto.KeyStore`](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.KeyStore.html),
"The table"; [ADR-0005](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0005-wrapped-key-row-shape.md);
[ADR-0006](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0006-scope-names-the-keys-owner.md)
Amendment A).

| Column | What it holds | What a reader of the dump learns from it |
|---|---|---|
| `id` | the surrogate primary key | insertion order, nothing more; the store never reads it |
| `scope_ref` | the keyed reference of the host's selector | which rows belong to the same scope, and how many versions each scope has; not which scope, without the reference subkey |
| `version` | the key version | how many times each scope's key has rotated |
| `namespace`, `name` | the key's provider id and version identity | the same names every message header already carries in the clear |
| `bits` | `256` | nothing |
| `wrapped` | the wrapping: an engine message under the root vault, or a Cloud KMS ciphertext | nothing readable without the root, or without decrypt access to the `CryptoKey` |
| `wrapping_shape` | `"engine_message"` or `"gcp_kms_ciphertext"` | which scopes keep their key in Cloud KMS |
| `key_id` | `NULL`, or the `CryptoKey` id for a Cloud KMS row | see below |
| `inserted_at`, `updated_at` | whatever the host writes | when each version was provisioned, if the host records it |

The selector is in none of those columns. A row is found by `scope_ref`, never
by the selector, because a selector in a column would publish the host's scope
identifiers beside every ciphertext; the reference is a keyed derivation for
exactly that reason.

The one exception is a Cloud KMS row's `key_id`. The vault derives the
`CryptoKey` id as an *unkeyed* SHA-256 digest of the namespace and the
selector, deliberately: a Cloud KMS key cannot be renamed or deleted, and a
keyed id would rename every scope's key on a root rotation (encryptor's
`Encryptor.Provider.GcpKms`, "The `CryptoKey` id"). The digest hides the
selector from anyone who cannot guess it. It does not hide it from anyone who
can: the namespace sits in the same row, so a reader who can enumerate
candidate selectors can confirm which one a Cloud KMS row belongs to. A host
whose selectors are guessable, and whose scope keys live in Cloud KMS, should
treat the scope list as visible to a dump. An `"engine_message"` row has no
`key_id` and does not have this property.

Integrity matters more than secrecy for these rows. A wrapping moved to
another scope's or version's row does not unwrap, and a row that will not
unwrap costs reads under that version only, never the scope's other versions
or the store; when it is the newest version, it also blocks writes for the
scope rather than letting one go under a key the store cannot vouch for. Two unique indexes, on `{scope_ref, version}` and `{namespace, name}`,
refuse the two duplicates that would otherwise surface years later as an
undecryptable row.

Pinned by: "never answers another scope's versions", "a row that does not
unwrap is invalid_key_descriptor, and carries nothing", "an older one is
skipped, and the versions that do unwrap still answer", "a row moved to
another scope fails closed, in the provider's own term", and the dispatch on
the row's wrapping shape
([`test/encryptor/ecto/key_store_repo_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/key_store_repo_test.exs));
encryptor's shared provider suite, run against the store
([`test/encryptor/ecto/key_store_conformance_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/key_store_conformance_test.exs)).

## The migrator's plaintext window

The migrator is the most sensitive component in either package. It is the one
process that decrypts every row it visits, and an operator typically runs it
against production from a release shell
([ADR-0002](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0002-migrator.md)
decision 11 and its Consequences). Its window is worth stating precisely.

**When a plaintext exists.** For one row, between loading it through the
source and dumping it through the target: the pass loads, applies the host's
`validate:` if the field declares one, encrypts, computes a folded blind
index from the value already in hand, and then compares and swaps
(`Encryptor.Ecto.Migrator.Pass`, "The order of operations for one row"). A
dry run does all of that except the swap, so a rehearsal holds exactly the
plaintexts a write would. A verification stops after the load. A row the probe
finds already migrated is not loaded, so its plaintext is never in hand.

**Where it does not go.** Not into the database: the only write is the target
ciphertext and, where one is folded in, the index value. Not into the report,
the checkpoint, an exception, a log line or the telemetry: a failure carries
the primary key, the schema, the field, and a reason reduced to atoms and
module names. A `validate:` that raises is reported as its module and nothing
else.

**What "no longer than a row" means.** The pass's own documentation says
nothing in it holds a value longer than a row. That is a statement about what the code
keeps a reference to. The pass holds no plaintext across rows, but Erlang
offers no way to wipe a binary, so the bytes stay in the process's memory until
the runtime reclaims it. Memory access to the running process is out of scope
here as it is in encryptor's page: that process can decrypt every scope it
visits, and nothing in this package changes that.

**What a crash mid-pass leaves.** Each batch is one transaction, with the
checkpoint written inside it. A batch that has not committed when the process
dies is rolled back by the database, so the table holds only the old bytes and
the new ciphertext of earlier, committed batches: no plaintext, and no row
half-written. The next run probes every row before rewriting it, so a re-run
converges on the same end state, and the compare-and-swap means a row the
application rewrote in the meantime is counted rather than overwritten with a
re-encryption of stale plaintext.

Pinned by: "a halted batch discards its writes and its checkpoint", "a row the
application rewrote mid-pass is counted, not clobbered", "a second run finds
every row already in the target state", "a validator that raises is
reported as the module and nothing else" and the three tests under "a reason
a host module returns"
([`test/encryptor/ecto/migrator_run_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/migrator_run_test.exs));
"a halted pass leaves its committed batches, and a resume finishes the rest"
([`test/encryptor/ecto/runbook_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/runbook_test.exs));
"a failure line names the row and the reason, and carries nothing else"
([`test/encryptor/ecto/migrator/cli_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/migrator/cli_test.exs));
"no reason from a raising closure carries the value it was holding"
([`test/encryptor/ecto/migrator/source_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/migrator/source_test.exs)).
The tests exercise a pass that halts on a failing row; none kills the
process mid-batch. The crash claim rests on the batch being one transaction
and on ADR-0002 decision 5's probe-first argument.

## What was tested, and how

**This package's own suites.** Every claim above is pinned by an ExUnit test
in this repository, named where the claim is made. The tests that need real
rows, the key store, the shred, the suspension store, the migrator's
compare-and-swap and resume, and the adapter's own dump and load path, run
against Postgres through a real `Ecto.Repo` rather than a mock. They are
tagged `:database`; a developer with no database reachable gets them skipped,
and CI sets a flag that turns an unreachable database into a failure, so a
green CI run means they ran. The blind index derivation is held to pinned
golden vectors, so a change to any byte of the construction fails a test. No
test here measures timing.

**The CI jobs.** Three, in
[`.github/workflows/ci.yml`](https://github.com/riddler/encryptor_ecto/blob/main/.github/workflows/ci.yml):
the full quality gate (format, compile with warnings as errors, Credo,
Dialyzer, the dependency audit, and the whole suite with coverage) on
Erlang/OTP 27 against a Postgres 16 service; the test suite on Erlang/OTP 26
against the same service; and a host on hackney 1.x, which resolves and
compiles this package from Hex ranges with no committed lock and runs no
tests.

**The cryptography is encryptor's.** This package performs no cryptography of
its own: encryption, decryption, the index key derivation and the Argon2id
slow hash are all calls into the vault. The published vectors, the
interoperability runs against another SDK, and the SP 800-38D construction
tests are encryptor's, and its
[What was tested against what](https://github.com/riddler/encryptor/blob/main/docs/explanation/threat-model.md#what-was-tested-against-what)
says what each covers and at which pins. The vault this package runs against
is the one `mix.exs` pins exactly.

## What this is not

This threat model is a self-review: written and reviewed by the maintainer,
who is the team's security lead, and checked by an LLM adversarial pass with
fresh context. That is not a third-party audit and not an independent
engineer's review. Tested against published vectors, self-reviewed, no formal
third-party audit: that is the honest summary, for this package as for the
vault, and a reader whose risk calls for more should commission it. The
[decision records](https://github.com/riddler/encryptor_ecto/tree/main/docs/adr)
hold the reasoning behind each part of this package, with the alternatives
that were weighed, for whoever does.
