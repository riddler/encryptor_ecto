# ADR-0005: a wrapped-key row declares its wrapping shape, in a column of its own

Status: proposed (2026-09-13)

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
