# ADR-0005: a wrapped-key row declares its wrapping shape, in a column of its own

Status: accepted (2026-09-13)

## Context

The store-backed key provider has shipped in this package for some time and
has never had a record of its own. `Encryptor.Ecto.KeyStore`
(`lib/encryptor/ecto/key_store.ex`, read at `a0717e9`) implements
`Encryptor.Provider` over a wrapped-key table, and
`mix encryptor.ecto.gen.key_store_migration`
(`lib/mix/tasks/encryptor.ecto.gen.key_store_migration.ex`, read at
`a0717e9`) writes that table's DDL into the host's tree. Both of them point
at `encryptor`'s records for their authority - the moduledoc's closing line
reads "Records: `encryptor` ADR-0002 decisions 4, 5 and 6; ADR-0003 decisions
1, 3, 4 and 9; this package's ADR-0002 decision 9" (`key_store.ex:123-124`,
read at `a0717e9`) - and nothing on this side says what a row *is*. The
moduledoc's own table (`key_store.ex:76-84`, read at `a0717e9`) is the only
written statement of the row, and a moduledoc is documentation of an
implementation rather than a decision about a contract.

That gap was free while there was one kind of wrapping. There are now two.

`encryptor`'s ADR-0007 (accepted 2026-09-13) adds a wrap-provider whose
wrapping is a GCP KMS ciphertext rather than an engine message produced by a
root vault. Its decision 6 returns

```elixir
@type provisioned :: %{
        tenant_ref: String.t(),
        version: pos_integer(),
        namespace: String.t(),
        name: String.t(),
        bits: 256,
        wrapped: binary(),
        key_id: String.t()
      }
```

(`enc docs/adr/0007-gcp-kms-wrap-provider.md:430-438`, read at `40957e6`;
shipped as `t:Encryptor.Provider.provisioned/0` at
`enc lib/encryptor/provider.ex:220-228`, read at `40957e6`) and says in the
same decision that it is a map rather than an `%Encryptor.Envelope.WrappedKey{}`
because "Reusing the struct would make a store holding both kinds unable to
tell them apart, which is the one thing such a store must be able to do. The
field names are otherwise identical, deliberately, so that a store can hold
one row shape with one extra column." (`enc 0007:459-462`, read at `40957e6`.)

Its consequences section states the problem and hands it here: "The store now
holds two blob kinds and must say which is which ... the column they land in
is `encryptor_ecto`'s or the host's, and a store that records only `wrapped`
cannot tell a reader which unwrap path to take. That is a schema question for
the downstream package and this record does not answer it"
(`enc 0007:650-657`, read at `40957e6`). Its open question 1 names the owner:
"`encryptor_ecto` owns it, because the column, the migration, and the row
shape are that package's under ADR-0002 decision 5 and ADR-0003 decision 9.
The minimum is probably a discriminator column, but 'probably' is why this is
a question and not a decision" (`enc 0007:851-856`, read at `40957e6`).

Those two upstream decisions are the ones that put the question here.
`enc` ADR-0002 decision 5 places the Ecto-backed provider in this package
"because it owns a schema, a migration, and a repo, and because ADR-0001's
boundary puts storage on that side" (`enc 0002-key-providers.md:234-236`,
read at `40957e6`). `enc` ADR-0003 decision 9 is titled "What this package
never sees is the storage" and is explicit: "It does not define a table, a
migration, a repo, a primary key, an index, or a transaction. `encryptor_ecto`
owns all of that" (`enc 0003-per-tenant-envelope.md:326-330`, read at
`40957e6`). What decision 9 *does* fix is the minimum a store must give back
so a descriptor can be reconstructed: the wrapping, the tenant reference and
the version, the namespace and the name, and enough ordering information
(`enc 0003:332-342`, read at `40957e6`). Everything past that minimum is this
record's, and the discriminator is past it.

### Why this is a new record and not an amendment

This package has four records and none of them is about the key store.

ADR-0001 is about vault-backed Ecto *field types* and where the tenant comes
from; a wrapped-key row is not a field and has no tenant scope to resolve.
ADR-0003 is the blind index and ADR-0004 is the migration off a prior
encryption scheme; neither touches key material.

ADR-0002, the migrator, is the near miss and the instructive one. Its Q3 asked
"Where the wrapped-key store lives, and whether R1 truly needs nothing here",
and its resolution of 2026-08-27 reads: "the store is an Ecto table in this
package, and the seam holds one notch narrower than drawn - R1/R4 get a
narrow key-store API on the store-backed provider, outside the migrator's
plan and task surface" (`0002-migrator.md:768-777`, read at `a0717e9`). That
resolution placed the store here and, in the same breath, put it *outside* the
migrator's surface. Its decision 9 - the no-DDL rule the key-store generator
borrows - is about who may issue `CREATE TABLE`, not about what a key row
contains. Amending ADR-0002 to carry the row contract would re-merge the seam
that resolution drew: the record would then decide both the migrator's plan
surface and the key store's schema, which is exactly the split-key-lifecycle
shape ADR-0002's Context argues against ("split key-lifecycle documentation is
how a shred gets half-performed", `0002-migrator.md:286-287`, read at
`a0717e9`) and its decision 9 then enacts ("No re-wrap, no key creation, no
shred ... This package's task list contains no verb that operates on a key",
`0002-migrator.md:504-506`, read at `a0717e9`).

So the row contract gets the record it never had. `docs/adr/README.md` says
new ADRs take the next number against a freshly fetched remote; `origin/main`
at `a0717e9` carries 0001 through 0004, so this is 0005.

## Decision

**1. A wrapped-key row declares its wrapping shape in a column of its own,
named `wrapping_shape`, and the vocabulary is closed at two.**

The column is `:string`, `null: false`. Its two permitted values are the
strings `"engine_message"` and `"gcp_kms_ciphertext"`, and the set is closed
here: a third wrapping shape is an amendment to this record, not a value a
host may invent.

| | `"engine_message"` | `"gcp_kms_ciphertext"` |
|---|---|---|
| what produced the wrapping | a root `Encryptor` vault, via `Encryptor.Envelope.provision/3` | `Encryptor.Provider.GcpKms`, via GCP KMS `Encrypt` (`enc` ADR-0007 decision 1) |
| what `wrapped` holds | a complete `Encryptor` message (an AWS ESDK message) | a GCP KMS ciphertext |
| `key_id` | `NULL` | required: the `CryptoKey` id the wrapping was produced under |
| what binds it | the encryption context (`enc` ADR-0003 decision 4) | GCP additional authenticated data over the same fields (`enc` ADR-0007 decision 5) |
| how a reader unwraps it | `Encryptor.Envelope.unwrap/2`, local, no network | GCP KMS `Decrypt`, one network round trip |
| what a misread costs | a `Decrypt` call on bytes that are not a GCP ciphertext | `Envelope.unwrap/2` on bytes that are not an engine message |

The last row is why a discriminator and not a sniff. Both shapes are opaque
binaries whose first bytes are attacker-influenced in the general case, and a
reader that guesses gets a failure that looks exactly like a wrong key. The
`wrapping_shape` column is one `varchar` per row and it removes the guess.

**A string and not a database enum, and not `Ecto.Enum`.** There is no schema
module to hang `Ecto.Enum` on: `Encryptor.Ecto.KeyStore` queries the table
schemalessly, by name, from provider state (`from(k in state.table, ...)`,
`key_store.ex:239-251`, read at `a0717e9`), which is what lets a host rename
the table. A native `ENUM` type would put the vocabulary in the database,
where extending it is a migration on every adopter and where the spelling is
the database engine's rather than this package's - and this package names no
adapter at all: `postgrex` is a test-only dependency, absent from the
published package (`mix.exs:107-123`, read at `a0717e9`). The vocabulary
belongs in this record and the enforcement belongs on the read side, where
decision 5 puts it. A host that wants a `CHECK` constraint over the two values
is welcome to one; this package does not generate it, for the same reason
ADR-0002 decision 9 gives about DDL.

**2. `key_id` is a second column, nullable, and it is stored rather than
re-derived.**

`:string`, `null: true`. It is `NULL` for every `"engine_message"` row, because
an engine message has no separate key id - the wrapping names its own keyring
material inside the message. It is required for every `"gcp_kms_ciphertext"`
row, and that requirement is a read-side rule rather than a `NOT NULL`,
because the constraint is conditional on another column's value and a
conditional constraint is not portable DDL.

Re-deriving it instead would be tempting and wrong. `enc` ADR-0007 decision 4
makes the id a deterministic function of the selector, so a reader *could*
recompute it - but the same decision keeps an escape hatch: "A host that wants
a different id policy - one key for all tenants, one key per region, an
externally-assigned id - supplies `key_id_fun` in `init/1`"
(`enc 0007:348-349`, read at `40957e6`). A host that supplies one, or that ever
changes its prefix or its derivation, has rows whose real id no longer matches
the recomputation. A key id is a fact about a wrapping that already happened. Facts
about wrappings that already happened are stored, not recomputed; that is the
same argument `enc` ADR-0003 decision 9 makes for `namespace` and `name`, which
are also derivable and are also columns.

**3. The default for rows written before the column existed is
`"engine_message"`, and it is correct rather than convenient.**

Every row that exists in any adopter's table today was written for a provider
whose only unwrap path is `Encryptor.Envelope.unwrap/2`: `unwrap_all/3` calls
it unconditionally, for every row, with no branch
(`key_store.ex:262-274`, read at `a0717e9`). A row that is not an engine
message is a row the shipped code cannot read, so there are none. The backfill
value is not a guess about history; it is the only value history can hold.

**4. The default does not survive the migration that sets it.**

The backfill default exists to make `null: false` possible on an existing
table in one statement. It is then set to `NULL`, in the same migration, and
the new-table generator never emits a default at all. Setting it to `NULL`
rather than dropping it is what `Ecto.Migration.modify/3` can express
portably, and on a `null: false` column the two are the same thing where it
matters: an insert that forgets the column fails at write time.

A permanent default would mean that a host inserting a GCP-wrapped row and
forgetting the column gets a row that claims to be an engine message and
fails, later, as an unwrap failure during someone else's rotation. This
package writes no rows - "It **mints nothing**" (`key_store.ex:57`, read at
`a0717e9`) - so every insert is host code, and the column with no default is
the only thing that makes a forgotten shape a write-time error instead of a
read-time mystery.

**5. Dispatch is per row, at read time, and an unrecognized shape is
`{:invalid_key_descriptor, _}`.**

Per row, and not per store, per vault, or per provider option. A host that
migrates from one shape to the other has a table holding both at once for the
length of the migration - that is precisely the host `enc` ADR-0007's
consequences says "will be found by the first host that migrates from one
shape to the other" (`enc 0007:656-657`, read at `40957e6`) - and a per-store
setting would make the mixed window unrepresentable.

The read side selects `wrapping_shape` and `key_id` alongside the six fields
it already selects, and `unwrap_all/3` branches per row. The mapping from the
stored string to the branch is an explicit function with one clause per
permitted value and a catch-all, and it is deliberately not
`String.to_existing_atom/1`: a store value is host data, and turning host data
into an atom-table lookup makes an unknown shape an `ArgumentError` raised
from inside a provider callback rather than a reason the contract already has
a word for.

The words it has are `t:Encryptor.Provider.reason/0`
(`enc lib/encryptor/provider.ex:196-202`, read at `40957e6`). Three rows are new
uses of an existing term, and none of them widens the vocabulary:

| the row | the answer |
|---|---|
| `wrapping_shape` holds a value this record does not list | `{:invalid_key_descriptor, {:unknown_wrapping_shape, value}}` |
| `wrapping_shape` is `"gcp_kms_ciphertext"` and `key_id` is `NULL` | `{:invalid_key_descriptor, :missing_key_id}` |
| `wrapping_shape` is `"engine_message"` and `key_id` is not `NULL` | `{:invalid_key_descriptor, :unexpected_key_id}` |
| the wrapping does not unwrap under its declared shape | `{:invalid_key_descriptor, :unwrap_failed}`, unchanged (`key_store.ex:267`, read at `a0717e9`) |

The first of those carries a stored value out of the provider, which the
module's own rule otherwise forbids - "a wrapped key's failure detail is the
last place a value should be allowed to ride along" (`key_store.ex:117-121`,
read at `a0717e9`). It is permitted here, and only here, because a
`wrapping_shape` is not a failure detail: it is one of a closed set of literals
this record publishes, derived from nothing, and an operator debugging a stray
row needs to see which literal it was. A `key_id` is not carried - decision 2's
missing-`key_id` arm is a bare atom - because a key id is a resource name.

`:invalid_key_descriptor` is right for all four because all four are the
same event: a row was found, and it does not reconstruct a descriptor. It is
not `{:unknown_key, selector}`, which is a settled negative answer, and it is
not `{:key_unavailable, selector}`, which is the one a caller retries - a row
with a shape nobody recognizes will not become recognizable on the next call.

**6. Adopters get a second generator task; the existing one keeps creating
whole tables.**

`mix encryptor.ecto.gen.key_store_migration` gains the two columns in the
table it writes, with no default on `wrapping_shape`:

```elixir
add(:wrapping_shape, :string, null: false)
add(:key_id, :string)
```

It cannot serve an existing adopter, and not by accident: `unwritten/2` globs
`*_create_<table>.exs` and refuses with exit 2 when one is present, because
"a repeated `CREATE TABLE` fails on the way up"
(`encryptor.ecto.gen.key_store_migration.ex:182-196`, read at `a0717e9`).

So the additive migration is a second task, and its shape is fixed here:

```elixir
def change do
  alter table(:<table>) do
    add(:wrapping_shape, :string, null: false, default: "engine_message")
    add(:key_id, :string)
  end

  alter table(:<table>) do
    modify(:wrapping_shape, :string,
      null: false,
      default: nil,
      from: {:string, null: false, default: "engine_message"}
    )
  end
end
```

Two `alter` blocks rather than one, because the column must exist and be
backfilled before its default can be dropped, and reversible by the `from:`
clause so `mix ecto.rollback` is available on the way back. It adds no index:
neither column is ever a lookup key - the lookup key is `tenant_ref`
(`key_store.ex:241`, read at `a0717e9`) - and an index on a two-valued column
over a table with one row per tenant per version buys nothing.

It follows the first generator in everything else: it writes one file, opens
no connection, issues no DDL itself, and the file is the host's to review,
commit and run on its own deploy schedule (this package's ADR-0002 decision 9).

**7. This is a breaking change for an adopter with an existing table, and it
says so out loud.**

A 0.4.0 `Encryptor.Ecto.KeyStore` reading a 0.3.0 table that has not run the
additive migration issues a query naming a column that does not exist. That
raises in `repo.all/1`, inside `rows/3`, where the bare rescue translates
every exception to `{:error, {:key_unavailable, selector}}`
(`key_store.ex:238-255`, read at `a0717e9`) - the reason a caller *retries*,
for a condition that will never resolve on its own.

The row contract therefore changes for existing rows, in the sense that
matters: the same rows, unchanged, stop being readable by the new code until
the host runs a migration. The code half of this record (`ece-9wp`) carries a
bold **Breaking** changelog entry naming the migration as the upgrade step,
and the upgrade note says to run the generated migration before deploying the
new version, not after.

## Upstream API assumptions

Decisions 1, 2 and 5 are written against `encryptor` surface that is decided
and, in the GCP half, not yet shipped. Stated here rather than assumed, in
the shape ADR-0001, ADR-0002 and ADR-0003 use, so that a wrong one is a
correction to this record and not a mystery in `ece-9wp`.

| | Assumed | Status at `40957e6` |
|---|---|---|
| A1 | `t:Encryptor.Provider.provisioned/0` carries exactly the six `WrappedKey` field names plus `key_id`, so a row is those seven values and a shape | shipped (`enc lib/encryptor/provider.ex:220-228`) |
| A2 | `key_id` is a `String.t()` and is never key material, so it may sit unencrypted in a column beside the wrapping | decided (`enc` ADR-0007 decision 6; the same decision keeps the plaintext key out of the return) |
| A3 | A GCP wrapping is unwrapped by a `Decrypt` call whose AAD is ADR-0003 decision 4's context, so a reader needs only `wrapped`, `key_id` and the row's own fields - never a second stored blob | decided (`enc` ADR-0007 decision 5) |
| A4 | `Encryptor.Provider.GcpKms` exists as a module a store can delegate an unwrap to | **not shipped**; open question 2 is where this lands |
| A5 | No further wrap-provider is in flight that would need a third `wrapping_shape` value before this record is accepted | true at `40957e6`: `enc` ADR-0002 decision 5's roadmap lists Vault transit as "later, on demand" (`enc 0002-key-providers.md:221`) |

A4 is the only one that is not yet code, and decision 5 is deliberately
written so that it does not need to be: a store with no GCP-shaped rows never
reaches that branch, and a store that has one and cannot serve it answers
`{:invalid_key_descriptor, _}` rather than crashing.

## The contract as typespecs

The row, as the read side sees it after decision 5:

```elixir
@typedoc "One row of the wrapped-key table, as selected by `rows/3`."
@type row :: %{
        tenant_ref: String.t(),
        version: pos_integer(),
        namespace: String.t(),
        name: String.t(),
        bits: 256,
        wrapped: binary(),
        wrapping_shape: String.t(),
        key_id: String.t() | nil
      }

@typedoc """
The closed vocabulary of decision 1, as the read side branches on it.
"""
@type wrapping_shape :: :engine_message | :gcp_kms_ciphertext
```

The six existing fields are unchanged and stay in the order
`Encryptor.Envelope.WrappedKey` fixes, so that `wrapped_key/1`
(`key_store.ex:277-286`, read at `a0717e9`) keeps building the struct from the
row without a translation step on the `"engine_message"` branch.

No addition to `Encryptor.Provider.reason/0` - decision 5 is a new *term*
inside `{:invalid_key_descriptor, term()}`, which is already open by
construction (`enc lib/encryptor/provider.ex:196-202`, read at `40957e6`).

## Worked example: a multi-tenant host app moves a tenant from a root vault to GCP

The host runs the store-backed provider with a root vault and has, say, nine
thousand rows. It decides to move its wrapping to GCP KMS.

1. It runs the second generator, reviews the file, commits it, and runs
   `mix ecto.migrate`. Every existing row is now
   `wrapping_shape = "engine_message"`, `key_id = NULL`, which is what those
   rows have always been. The default is gone by the end of the migration.
2. It deploys the new version. Nothing about resolution changed for any
   tenant: decision 5's branch sends every row down
   `Encryptor.Envelope.unwrap/2`, exactly as before.
3. For one tenant, it calls `provision/2` on a `Encryptor.Provider.GcpKms`
   and writes the returned map - including `key_id` - as a new row at a new
   version, with `wrapping_shape = "gcp_kms_ciphertext"`.
4. That tenant's table now holds both shapes at once. `decryption_keys/2`
   returns both versions, newest first, and unwraps each down its own branch:
   one `Decrypt` round trip for the new row, one local unwrap for the old.
   Application ciphertext is untouched throughout - the two shapes differ
   only in one small blob per tenant per version (`enc` ADR-0007 decision 1).
5. When the host is satisfied, it deletes the old rows. That is a shred of the
   old wrapping and nothing else, because the tenant's data is already
   readable under the new one.

The step that would have been impossible without this record is 4. A store
recording only `wrapped` has to guess at step 4 for the life of the migration,
and the guess it gets wrong reports as a decrypt failure.

## Open questions

1. **Should a mixed-shape table be refusable?** A host that never intends to
   run two shapes might want a provider option that makes any row outside one
   declared shape an error at read time, so that a stray row is loud rather
   than merely slow. This record does not add the option: it would be a
   configuration surface defending against a row only the host can write, and
   nobody has written one yet. Owner: this package. Revisit if a host reports
   a stray row.

2. **Where does the GCP branch's provider state come from?** Decision 5
   branches per row, which means a store holding a `"gcp_kms_ciphertext"` row
   needs a configured GCP client to unwrap it, and today
   `Encryptor.Ecto.KeyStore`'s state holds a `root_vault` and no GCP client at
   all (`key_store.ex:146-151`, read at `a0717e9`). Whether that arrives as a second
   provider option, as a delegation to `Encryptor.Provider.GcpKms`, or as a
   composite provider is an implementation question this record deliberately
   leaves open, because all three satisfy decisions 1 through 5 and the choice
   should be made with the code in hand. Owner: `ece-9wp`.

3. **Does the `rescue` in `rows/3` mislabel a schema error?** Decision 7 names
   the consequence: a missing column reports as `{:key_unavailable, selector}`,
   a retryable reason for a permanent condition. Widening that rescue is a
   change to the failure vocabulary of every store error, not just this one,
   and it is already someone else's question (`ece-s8b`). Named here so the
   two are not decided separately by accident.

## Consequences

**The store finally has a record, and it is a small one.** Four columns of
decision - two of them new - and the six fields `enc` ADR-0003 decision 9
already fixed. That is the whole row contract, and it now lives somewhere a
reader can find it without reading a moduledoc.

**Every adopter runs a migration, and the failure mode if they forget is a
retryable reason for an unretryable condition.** Decision 7 says so plainly
rather than hoping. This is the cost of adding a `null: false` column to a
shipped table, and the alternative - a nullable column whose `NULL` means
"engine message" - trades an explicit upgrade step for a permanently ambiguous
column, which is the thing decision 4 refuses on the write side.

**A third wrapping shape is an amendment, and cheaply so.** The vocabulary is
closed in this record, the branch is one function with one clause per value,
and the catch-all already answers correctly for a value the code does not
know. A Vault transit provider - which `enc` ADR-0002 decision 5's roadmap
lists beside GCP KMS as a material source, "later, on demand"
(`enc 0002-key-providers.md:221`, read at `40957e6`) - would add one value, one
clause, and one row to decision 1's table.

**The guess is gone and the network call is now predictable.** Before this
record, a reader of a mixed store either guesses or tries both, and trying
both means a GCP `Decrypt` round trip on every engine-message row during a
migration. After it, each row costs exactly the unwrap its shape requires.

**Closing the vocabulary here puts this record in `encryptor`'s release
order, and that is a real cost.** A new upstream wrap provider cannot have
its rows stored until this record is amended with the value and the row in
decision 1's table, so the sequence is: upstream ships the provider, this
record takes an amendment, `encryptor_ecto` ships the branch. The
alternative - an open vocabulary the store passes through - removes the
coupling by removing the guarantee, because then a typo is a shape and the
catch-all in decision 5 never fires. The coupling is the price of the closed
set and it is paid once per provider.

**This package now holds a schema decision it once disclaimed.** ADR-0002
decision 9 says this package issues no DDL, and it still issues none - but it
now decides the content of two columns rather than only transcribing the six
`encryptor` fixed. That is the natural consequence of `enc` ADR-0003 decision
9 drawing the line where it did, and it is worth naming: the next question
about what a key row may contain comes here, not upstream.

## Note (2026-09-13): the second generator's name, corrected counts and anchors, and open question 3 answered

This record's decisions are unchanged. What follows is the accuracy pass its
reviews asked for, plus the one thing the record deliberately left for the code
half to name. Every code cite below was read at `encryptor_ecto` `f441f66` and
every upstream cite at `encryptor` `ec6a84d`. No Status word flips; this Note
carries the record's `proposed` status.

### 1. The second generator task, named

Decision 6 fixes the additive migration's shape and decides that it is a second
task without ever saying what the task is called. The code half (`ece-9wp`)
chose it, which is where that choice belonged - the record's decision forces the
task, and naming it is implementation. It is:

| | |
|---|---|
| task | `mix encryptor.ecto.gen.key_store_shape_migration` |
| module | `Mix.Tasks.Encryptor.Ecto.Gen.KeyStoreShapeMigration` |
| flags | `[--table NAME] [--migrations-path PATH]`, the same pair the create task takes |
| exit codes | `0` on a written file, `2` on a usage failure, via `Encryptor.Ecto.Migrator.CLI.usage_error/1` |

(`lib/mix/tasks/encryptor.ecto.gen.key_store_shape_migration.ex`, ece
`f441f66`.) Decision 6 is read as naming this task; nothing else about it
changes.

### 2. The first Consequences bullet miscounts, twice

It reads: "Four columns of decision - two of them new - and the six fields
`enc` ADR-0003 decision 9 already fixed." Both halves are wrong against this
record's own Context and typespecs.

The row has eight fields, not ten of which four are decided here: the six
`Encryptor.Envelope.WrappedKey` fixes, plus `wrapping_shape` and `key_id`. This
record decides **two** columns, and both of them are new. And `enc` ADR-0003
decision 9 does not fix six fields: its minimum list is the wrapping, the
tenant reference and the version, the namespace and the derived name, and
"enough ordering information to return live versions newest first" - `bits` is
not in it (`enc docs/adr/0003-per-tenant-envelope.md:332-342`, `ec6a84d`). The
six fields are `Encryptor.Envelope.WrappedKey`'s; decision 9's list is a subset
of them.

Read the bullet as: *Two columns of decision, both of them new, beside the six
`Encryptor.Envelope.WrappedKey` fixes and the timestamps the generator emits.*
The typespec in "The contract as typespecs" is correct as written and is what a
reader should trust.

### 3. Anchors that run past or short of what they quote

| where | as cited | correct |
|---|---|---|
| Context, the consequences quote | `enc 0007:650-657` | `enc 0007:650-656` - line 657 is the sentence after the quote |
| Context, open question 1 | `enc 0007:851-856` | `enc 0007:852-855` - 851 is the question's own heading line, and the quote stops at "not a decision" |
| Decision 5, the ride-along rule | `key_store.ex:117-121`, at `a0717e9` | `key_store.ex:181-184`, at `f441f66` |
| Decision 1, "`postgrex` is a test-only dependency" | `mix.exs:107-123`, at `a0717e9` | `mix.exs:115-116`, at `f441f66` - the two `only: :test` lines are the claim; 107-114 is the comment above them |

Decision 6's exit-2 cite belongs in a different category and is corrected
separately. `encryptor.ecto.gen.key_store_migration.ex:182-196` at `a0717e9`
covered both `unwritten/2` and the sentence the record quotes, so it neither
ran past nor fell short. What is wrong there is the **attribution**: the
record says `unwritten/2` "refuses with exit 2", and `unwritten/2` returns
`{:error, message}` and nothing else. The refusal is split across three
functions, and a complete cite names all three - `unwritten/2`, which produces the
error and carries the glob (`:211-217`); `already_written_message/1`, which
is where the quoted "a repeated `CREATE TABLE` fails on the way up" actually
lives (`:219-225`); and `main/1`, which routes the error to
`Encryptor.Ecto.Migrator.CLI.usage_error/1` (`:98-105`), where the `2`
itself is returned (`lib/encryptor/ecto/migrator/cli.ex:113-117`). All at
`f441f66`.

One quotation also re-renders its source's punctuation: Context quotes `enc`
open question 1 as `but 'probably' is why this is a question`. Upstream has
double quotes - `but "probably" is why this is a question` (`enc
0007:855`, `ec6a84d`). The words are exact; only the quote marks were
downgraded to fit an outer quotation.

### 4. Decision 5's ride-along paragraph attributes an arm to the wrong decision

It closes: "A `key_id` is not carried - decision 2's missing-`key_id` arm is a
bare atom - because a key id is a resource name." The
`{:invalid_key_descriptor, :missing_key_id}` arm is in **decision 5's own
table**, three rows above. Decision 2 decides that `key_id` is a stored,
nullable column and that the requirement is conditional and therefore read-side;
it names no arm. Read the sentence as "this decision's own missing-`key_id` arm
is a bare atom". The rule it states - a key id is a resource name and does not
ride out of the provider - is unchanged and correct.

### 5. The atom type beside the string column

"The contract as typespecs" declares
`@type wrapping_shape :: :engine_message | :gcp_kms_ciphertext` immediately
beside a row whose `wrapping_shape` field is `String.t()`, while decision 5
forbids `String.to_existing_atom/1`. The two are not in tension and the record
should say which is which: **the string is the stored value and the atom is the
branch label.** The mapping between them is the explicit one-clause-per-value
function decision 5 requires, so an unknown stored string reaches the catch-all
and becomes `{:invalid_key_descriptor, {:unknown_wrapping_shape, value}}` rather
than an `ArgumentError` from an atom-table lookup. No stored string is ever
converted to an atom.

### 6. Decision 7's breaking claim, phrased without release numbers

Decision 7 opens "A 0.4.0 `Encryptor.Ecto.KeyStore` reading a 0.3.0 table that
has not run the additive migration". The claim does not depend on which
releases those are. Read it as: **a `KeyStore` that selects `wrapping_shape`
and `key_id` reading a table created before decision 1's columns existed, in a
deploy that has not run the additive migration.** That is true of any pair of
releases either side of this record, which is the property decision 7 is
asserting.

### 7. Decision 7's failure-mode sentence is stale, and open question 3 is answered

Decision 7 describes *how* a pre-migration read fails: the query "raises in
`repo.all/1`, inside `rows/3`, where the bare rescue translates every exception
to `{:error, {:key_unavailable, selector}}`" (cited to `key_store.ex:238-255`
at `a0717e9`). That bare rescue is gone. `rows/3` now rescues only conditions a
retry can resolve and reraises everything else with its original stacktrace
(`lib/encryptor/ecto/key_store.ex:408-414`, `f441f66`), so a pre-migration read
raises the `Postgrex.Error` naming the missing column instead of reporting a
retryable reason.

**Decision 7's substance is unchanged**: the change is still breaking, and the
upgrade step is still to run the additive migration before deploying the new
version. What changed is only the failure a host that forgets it sees - a loud
crash naming the real cause rather than a `key_unavailable` that never clears.
The second Consequences bullet ("the failure mode if they forget is a retryable
reason for an unretryable condition") is stale in the same way and for the same
reason; the migration it describes as mandatory still is.

**Open question 3 - "Does the `rescue` in `rows/3` mislabel a schema error?" -
is answered: yes, and it is fixed.** The rescue is narrowed to
`DBConnection.ConnectionError`, a `Postgrex.Error` whose server code is in an
explicit transient list, a `Postgrex.Error` carrying no `:postgres` map at all
(which means the server was never reached), and the `RuntimeError` a repo whose
supervisor has not started raises; everything else is reraised
(`lib/encryptor/ecto/key_store.ex:461-472`, `f441f66`). The fix **adds no term
to `t:Encryptor.Provider.reason/0`**, which is what made it settleable here
rather than upstream: a raise is not a reason. Two properties of the narrowing
are worth recording because they are decisions and not accidents:
`undefined_table`, `undefined_column`, `invalid_schema_name` and
`insufficient_privilege` are deliberately absent from the transient list
(`:428-452`), and a `Postgrex.Error` with no `:postgres` map is classed
transient *by construction* - a driver error that never reached the server is
the connection being gone.

### 8. Two things the record does not name and the implementation has

Recorded here so a reader of the record is not surprised by the module.

- **`Encryptor.Ecto.KeyStore` takes a `:prefix` option in `init/1`**
  (`lib/encryptor/ecto/key_store.ex:598-605`, `f441f66`), defaulting to `nil`,
  which places the wrapped-key table in a non-default schema. It is singular by
  the same argument `Encryptor.Ecto.Migrator`'s prefix is, it is passed as a
  query option rather than spelled into the query source (`:416-421`), and the
  generators deliberately write no prefix into their migration files - `mix
  ecto.migrate --prefix` is Ecto's own way to place one. No decision in this
  record names the option; nothing in this record forbids it either, and it
  touches neither the row shape nor the dispatch.
- **The generated table carries nullable `inserted_at` and `updated_at`
  timestamps** beside the eight fields, which "The contract as typespecs" omits
  because `rows/3` does not select them. This module neither writes nor reads
  them.

## Note (2026-09-13): the operator accepted this record

The Status line at the head of this file now reads `accepted (2026-09-13)`,
and the index row in `docs/adr/README.md` says the same. Nothing else in the
record changes: no decision, assumption, open question or consequence is
reopened, reworded or withdrawn by the acceptance.

Two sentences elsewhere in the file name the status the flip replaced. Both
are historical rather than wrong, and neither is edited:

- The Note above closes "No Status word flips; this Note carries the record's
  `proposed` status." That was true of that Note. The flip is this one, and it
  happened after it - after the accuracy pass that Note records, which is the
  order acceptance wants.
- Assumption A5 is phrased "... before this record is accepted". That moment
  is now, and A5 held at it: the one further wrap record `encryptor` carries
  is its ADR-0008, which is keyring-backed - "The classification stands: AWS
  KMS is keyring-backed, it maps to the engine's own AWS KMS keyrings"
  (`enc docs/adr/0008-aws-kms-keyring-backed.md:39-41`, read at `6acefff`) -
  so its wrapping is an engine message and it needs no third
  `wrapping_shape` value.

Every claim this record makes was re-verified immediately before the flip:
this package's cites against `encryptor_ecto` main at `32b503e`, the upstream
cites against `encryptor` main at `6acefff`. Decisions 1 through 7 are
implemented in `lib/encryptor/ecto/key_store.ex` and in the two generator
tasks at `32b503e`, and the one claim the code overtook - decision 7's
bare-rescue sentence - was already recorded as stale in the Note above,
together with the answer to open question 3.

## Note (2026-09-13): assumption A4 is unmet rather than unshipped, open question 2's interim answer, and five accuracy corrections

Every upstream cite below was read at `encryptor` `efd71c5`, and every cite
into this package at `encryptor_ecto` `6592581`. Line anchors into
`lib/encryptor/ecto/key_store.ex` are given as that file stands in the commit
this Note ships in, because the same commit rewrites one of its comments and
moves everything below it by a line. No decision, assumption, open question or
consequence is withdrawn, reworded or reopened; no Status word flips. This Note
carries the status the accepted record already has.

### 1. A4's status cell is right about the consequence and wrong about the cause

The "Upstream API assumptions" table records A4 - "`Encryptor.Provider.GcpKms`
exists as a module a store can delegate an unwrap to" - as **not shipped**
(`:312`). Read that cell as **assumption unmet: the module exists, the public
unwrap does not.**

`Encryptor.Provider.GcpKms` is shipped
(`enc lib/encryptor/provider/gcp_kms.ex`, read at `efd71c5`). What it does not
expose is an unwrap a store could call: its public surface is `init/1`,
`encryption_key/2`, `decryption_keys/2`, `provision/2` and `crypto_key_name/1`
(`:246`, `:284`, `:300`, `:325` with a second clause at `:337`, and `:375`),
and the function that turns a
stored row back into key material is `defp unwrap/3` (`:471`). A store holding
a GCP-shaped row therefore has no callable entry point, which is the same
practical position "not shipped" described - but the fix is a public function
on an existing module rather than a new module, and a reader planning open
question 2's answer should know which.

The consequence the cell was drawn for is unchanged: A4 is still the one
assumption that is not code, and decision 5 is still written so that a store
which cannot serve such a row answers rather than crashes.

The same loose phrasing sits in the implementation's comment, which said "the
module it would delegate to is not shipped upstream". It now reads with this
Note's wording (`lib/encryptor/ecto/key_store.ex:559-564`).

### 2. Open question 2's interim answer, and the term it publishes

Open question 2 - which of a second provider option, a delegation to
`Encryptor.Provider.GcpKms` or a composite provider supplies the GCP branch's
client - is **still open, and its owner is unchanged**. What this Note records
is that the code already holds a deliberate interim answer, and that the answer
is a published term rather than an internal detail:

    {:invalid_key_descriptor, {:unsupported_wrapping_shape, "gcp_kms_ciphertext"}}

A well-formed GCP row that this store cannot serve answers with that reason
(`lib/encryptor/ecto/key_store.ex:566`), and the moduledoc
already lists it beside the other `:invalid_key_descriptor` arms (`:224-229`).
Decision 5's own table lists four arms and this is the fifth; read the table as
those four plus this one. The arm is not a fifth *decision* - decision 5
already decides that an unrecognized or unservable shape answers rather than
crashes, and this is that answer for the one shape the record names and the
store cannot serve.

Two properties of the term are decisions rather than accidents, and are the
reason it is written down here:

- The string inside it is the **stored** `wrapping_shape` value, not an atom.
  Decision 5 forbids `String.to_existing_atom/1`, so the reason carries the
  column's own bytes and a caller matching on it matches a binary.
- It sits **inside** `:invalid_key_descriptor` rather than beside it, so it
  adds no term to `t:Encryptor.Provider.reason/0` - the same property that made
  open question 3 settleable in this record rather than upstream.

Whichever way open question 2 lands, this term is what a host sees until it
does. If the answer is a public upstream unwrap, this arm becomes unreachable
for a store configured with the client and keeps its meaning for one that is
not.

### 3. The ride-along row in the anchor table is a SHA refresh, not an over-run

The Note above collects four rows under "Anchors that run past or short of what
they quote". The third row - decision 5's ride-along rule, `key_store.ex:117-121`
at `a0717e9` corrected to `:181-184` at `f441f66` - does not belong under that
heading. The original span quoted what it said it quoted; what changed is the
file. Read that row as a **SHA refresh whose anchor moved**, together with a
one-line **narrowing**: `a0717e9:117-121` is byte-for-byte `f441f66:180-184`,
so the corrected `:181-184` drops the lead-in line `:180` ("answer for a
wrapping the rewrap pass has not reached yet. The") that the original span
carried.

Worth naming beside it: **two** rows of that table carry a refreshed SHA, not
one. Row 4 - decision 1's "`postgrex` is a test-only dependency", `mix.exs`
`:107-123` at `a0717e9` corrected to `:115-116` at `f441f66` - is a pure span
correction that re-labelled the SHA along with it: `mix.exs` is byte-identical
at the two SHAs, so `a0717e9:115-116` are the same two lines and the refresh
buys nothing.

The rest of this record's `a0717e9` cites were not refreshed, and the list
below is illustrative rather than exhaustive - the file carries 23 of them.
Decision 5's own read-side arms table still cites `key_store.ex:267` (`:220`
of this file); decision 3 cites `:262-274` (`:171`); decision 4 cites `:57`
(`:188`). Decision 6's body cite,
`encryptor.ecto.gen.key_store_migration.ex:182-196` (`:251`), still reads
`a0717e9` in the decision itself, and is separately re-anchored at `f441f66`
by the trailing paragraph of the Note above, for attribution rather than for
the SHA - so it belongs on neither list cleanly, and this sentence is where it
is accounted for. All of them are historical cites to a historical SHA, which
is legitimate; what they are not is a set that has been checked against
today's file, and a reader refreshing one should not read the table above as
having refreshed them.

### 4. The two upstream span corrections are right, and their stated reasons are not

Rows 1 and 2 of that same table give the correct spans and describe the
boundary lines loosely. Both spans stand; read the reasons as follows
(`enc docs/adr/0007-gcp-kms-wrap-provider.md`, read at `efd71c5`).

- The consequences quote: `650-656` is right. Line `657` is not "the sentence
  after the quote". The sentence it belongs to begins on `654` ("That is a
  schema question ..."), and what the quote cuts is that sentence mid-`656`,
  after its first word (`"it"`); `657` carries the end of the clause that
  follows the semicolon. The original `650-657` therefore over-ran by part of
  one sentence, not by a whole one, and this record quotes that same tail
  deliberately elsewhere (`enc 0007:656-657` at `:199`).
- Open question 1: `852-855` is right. Line `851` is not "the question's own
  heading line" alone - it carries the bolded question **and** the first two
  words of the prose that follows it, and the quote begins mid-`852`.
  Symmetrically, `855` is included only as far as "not a decision"; the rest of
  that line continues the sentence.

### 5. Item 1 records the task's name; it does not write it into decision 6

Item 1 of the Note above closes "Decision 6 is read as naming this task".
Decision 6 names no task, which is what item 1's own lead-in says. Read that
closing sentence as **"the name is recorded here"**: the record forces a second
generator task, the code half chose what to call it, and this file is where the
choice is written down. Nothing is read back into decision 6, and a later
decision may rename the task without contradicting the record.

### 6. The exit-codes row understates the second exit-2 arm

Item 1's table gives the shape generator's exit codes as "`0` on a written
file, `2` on a usage failure". `2` has a second arm the task's own moduledoc
states and its own code implements: an additive migration for this table
already exists in the migrations directory, in which case the generator writes
nothing and never overwrites or duplicates one. The moduledoc row is
`lib/mix/tasks/encryptor.ecto.gen.key_store_shape_migration.ex:51` and the
arm is `defp unwritten/2` at `:195-200`, which globs
`*_add_wrapping_shape_to_<table>.exs` (ece `6592581`). Read the row as "`2` on
a usage failure, or on an additive migration for this table that already
exists". The routing is unchanged: `main/1` (`:90-97`) sends both arms to
`Encryptor.Ecto.Migrator.CLI.usage_error/1` (`:95`).

### 7. Item 8's `:prefix` sentence and its anchor name different functions

Item 8 says `Encryptor.Ecto.KeyStore` "takes a `:prefix` option in `init/1`"
and anchors it at `key_store.ex:598-605` at `f441f66`, which is the private
validator rather than `init/1`. Both halves are true of different lines, and at
ece `6592581` both have moved. The cite is:

| what | where |
|---|---|
| `init/1` reads the option | `lib/encryptor/ecto/key_store.ex:327` and `:332` (`{:ok, prefix} <- prefix(opts)`) |
| the option is validated | `:624-631` (`defp prefix/1` and its `@spec`) |
| the option is documented | `:50`, with the singular-placement argument at `:52` |
| it is passed as a query option, not spelled into the source | `:441-446` (the comment and `defp query_opts/1`) |

Nothing item 8 claims about the option changes, and item 8's disclaimer stands:
no decision in this record names `:prefix`, and nothing here decides it.

## Note (2026-09-14): the `crypto_key_name` arity, what "23 of them" counts, and the shape generator's refusal after it moved into `Migrator.CLI`

Three cites in the Note above are off by an arity, by a counting scope, or by
a commit. Each is corrected here by addition; no sentence above is withdrawn,
reworded or removed, and no status word flips. Upstream cites were read at
`encryptor` `v0.4.1` = `4c8fbe9`, the version this package's `mix.lock`
resolves (`mix.lock:14`, `"encryptor", "0.4.1"`); cites into this package were
read at `encryptor_ecto` `2413470`.

### 1. `crypto_key_name` takes two arguments

Item 1 above lists `Encryptor.Provider.GcpKms`'s public surface and ends the
list with `crypto_key_name/1` (`:664`). The function is arity 2. Its `@spec`
is `crypto_key_name(state(), Provider.selector()) :: String.t()` and its head
is `def crypto_key_name(state, selector) when is_binary(selector)`
(`enc lib/encryptor/provider/gcp_kms.ex:375-376`, read at enc `4c8fbe9`).
Read the list as naming `crypto_key_name/2`.

Nothing else in item 1 changes. The surface it enumerates is the same surface,
and the point it is drawn for - that no public unwrap sits among them, so a
store holding a GCP-shaped row has no callable entry point - does not turn on
the arity.

### 2. "23 of them" counts the record above that Note, not the whole file

Item 3 above closes "the file carries 23 of them" (`:735`). Read that figure
as **scoped to the file above the 2026-09-13 Note it sits in**, where it is
exact: lines 1 to 643 at `2413470` - everything above that Note's heading at
`:644` - carry 23 mentions of `a0717e9`, which is the body the sentence was
written of.

A bare count over the whole file answers higher, and answers differently over
time: the 2026-09-13 Note names the SHA six times itself, and every later
Note that names it - this one included - moves the number again. So a reader
wanting today's whole-file figure should count it at a named SHA and say
which SHA. What the sentence is doing is unaffected: the list of unrefreshed
cites beside it is illustrative rather than exhaustive, and that remains true
under either scope.

### 3. The shape generator's second exit-2 arm now lives in `Migrator.CLI`

Item 6 above anchors that arm at `defp unwritten/2` (`:195-200`) and its
routing at `main/1` (`:90-97`), both labelled ece `6592581`. Those cites
still resolve at their own SHA and are left standing. At `2413470` the glob
and the routing have moved into the generator grammar the migrator CLI now
shares across the family:

| what | where, at ece `2413470` |
|---|---|
| the already-written refusal | `Encryptor.Ecto.Migrator.CLI.gen_unwritten/3`, `lib/encryptor/ecto/migrator/cli.ex:502` (`@spec` at `:501`) - **`defp`, private** |
| the glob it runs | `cli.ex:503`, built from the calling task's own `:verb` and table rather than spelled into the task |
| the routing | `CLI.gen/2` (`cli.ex:166`, `@spec` at `:165`), whose `else` sends `{:error, message}` to `usage_error/1` (`:171`) |
| where `2` is returned | `CLI.usage_error/1` (`cli.ex:118`, `@spec` at `:117`) - public, and the one half of this path a caller can reach by name |
| the task's own half | `main/1` is `lib/mix/tasks/encryptor.ecto.gen.key_store_shape_migration.ex:89`, and its whole body is the `CLI.gen/2` call at `:90-97` |

`gen_unwritten/3` being private is the part worth naming beside the move: the
refusal is not callable surface, and a reader looking for it by name outside
`Encryptor.Ecto.Migrator.CLI` will not find it.

The behaviour item 6 records is unchanged - where an additive migration for
this table already exists the generator writes nothing, overwrites nothing and
returns `2` - and so is item 6's reading of the exit-codes row. What moved is
where the code implementing it lives.

This Note corrects three cites and asserts no rule of its own. It leaves the
enumeration of the generators' exit behaviour to the generator tasks' own
suite. No decision, assumption, open question or consequence changes, and no
status word above flips.

Provenance: campaign RF048, bead ece-42x (folding ece-2bc and ece-8pt).
