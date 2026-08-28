# What changes when you move off cloak_ecto

The mechanical part of this migration is small. A `cloak_ecto` host's encrypted
fields are type modules the schemas name, and moving them onto this package is
a two-line change inside each of those modules with the schemas untouched
(ADR-0001's context, and its worked example). Everything hard about the move is
somewhere else: the *meaning* of an encrypted column changes, and a host that
ports the modules without noticing that will be surprised by the parts of its
own system that stop working.

This page is about that change of meaning. It has no steps and nothing to copy;
the runbook is the how-to guide, and the flag tables are the mix tasks' own
documentation. What follows is what a reviewer needs to hold in their head
before reading either of them.

Throughout, the host in the examples is the one ADR-0004's worked example uses:
a multi-tenant card-processing application with `accounts`, `budgets` and
`transactions`, an encrypted cardholder tax identifier and free-text note, and
one exact-match lookup - find an account by contact email.

## One key becomes a key per tenant

`cloak_ecto`'s Ecto layer has no per-user or per-tenant key model; its README
says so directly, and ADR-0004 records it as C7. A cloak host's encrypted rows
are all under one key. Rotating that key is a whole-table operation, and the
blast radius of losing control of it is every row in the database.

On this stack the tenant is part of how a value is encrypted. The type resolves
which tenant a value belongs to and names it to the vault, which resolves that
tenant's own key material (ADR-0001 decision 5, and its acceptance amendment 1,
under which the tenant passes as `key:` rather than as a context pair the caller
supplies). Two accounts holding the same tax identifier produce unrelated bytes,
and neither is readable with the other's key material.

That is a smaller blast radius, and it is also a new failure mode: a row can now
be written under the *wrong* key, which is not a thing that can happen when
there is only one. Most of the rest of this page is about the machinery ADR-0001
put in place so that this failure is loud rather than durable.

## The encryption context, and the substitution it forbids

Cloak's ciphers take a plaintext and give back a ciphertext. The `encryptor`
vault takes a plaintext *and an encryption context*, and binds that context into
the message as additional authenticated data. This package's job is to populate
that context so that a caller cannot forget it: the table and the column are
derived from the schema once, at field-declaration time, and frozen as declared
values (ADR-0001 decision 4, as amended at acceptance). The tenant pair is in
the context too, but this layer does not put it there - it names the tenant, and
the vault injects the pair itself (ADR-0001 acceptance amendment 1). What the
message is bound to is therefore the tenant, the table and the column together.

What that buys is anti-substitution. A ciphertext lifted out of
`accounts.tax_id` and written into `accounts.contact_email`, or into another
tenant's row, does not decrypt into the wrong place - it fails authentication
(ADR-0001's context, and its Consequences). ADR-0001 calls this the main reason
to prefer this stack over cloak, and it is worth restating what it is *not*: it
is a check at read time. A wrong tenant at decrypt time is a loud error; a wrong
tenant at encrypt time is a durably wrong row, and nothing about the AAD helps
there. The context is a backstop, not a substitute for resolving the tenant
correctly.

Two consequences fall out of freezing the context at declaration. A physical
rename of a table or column no longer invalidates every stored row, because the
declared values can be pinned while the physical ones move. And two fields can
never share a declared table/column pair, because a uniqueness check across
declarations refuses it - if they could, they would be silently mutually
substitutable, which is the property this whole mechanism exists to deny.

## Fail-closed tenant scope, and the audit it implies

An `Ecto.Type` callback is one of the most context-starved positions in the
stack. `dump/3` receives the value, a dumper, and the type params; it never
receives the struct, the changeset, the repo, or the caller's options. So the
tenant has to arrive out of band, and ADR-0001 decision 5a settles that as an
explicit process scope the host sets at the edge of a unit of work.

Process scope does not propagate, and ADR-0001 decision 5b refuses to pretend it
does. A `Task`, a `Task.Supervisor` child, an Oban worker, a GenServer doing a
write on someone else's behalf - each begins with an empty scope, and the host
propagates deliberately at each of those boundaries. **This is the real cost of
adopting the package.** Not the type modules, which are two lines; the audit of
every place a unit of work begins in the host's codebase.

The audit is unavoidable rather than merely recommended, because a dump with no
tenant in scope raises (ADR-0001 decision 5c). There is no default tenant, no
`nil` tenant, no global-key fallback, no log line and carry on. ADR-0001 lists
that fallback among its rejected alternatives and rejects it hardest of the
five, and the reasoning is worth carrying: a fallback converts one loud failure,
found once on a developer's first test run, into a silent per-row failure
discovered whenever somebody next tries to read those rows. Loads raise the same
way, deliberately, because a legible "no tenant in scope" beats an
authentication failure that reads like data corruption.

A cloak host feels this as new failures in places that never had to think about
tenancy at all - factories, seeds, test setup, the reporting job that sweeps
every account nightly. Those failures are the mechanism working. What they are
telling you is that those code paths were already ambiguous about which tenant
they were acting for, and cloak's single key was answering the question by
making it not matter.

## Crypto-shredding, and the field that opts out

Because a tenant's rows are under that tenant's key material, destroying the key
material destroys the readability of the rows. That is crypto-shredding, and for
a host with a deletion obligation it is often the reason the per-tenant key model
was wanted in the first place. It is the vault's operation, not this package's -
this package's task list contains no verb that operates on a key (ADR-0002
decision 9) - but it is this layer's field declarations that decide which rows
participate.

A field declared `tenant: :none` does not participate. It omits the tenant from
its context entirely, and its ciphertexts are therefore not shreddable with a
tenant key (ADR-0001 decision 5e). That is the correct declaration for a
genuinely shared reference table, and it is written at the field, in the schema,
where the reviewer sees it beside the column it applies to. Nothing about it is
inferred: a global field cannot ride a tenant-scoped vault with the tenant
quietly left out, so opting out is a configuration a host builds on purpose
rather than one it drifts into. ADR-0001 decision 5e, with its acceptance
amendment 3, is where the requirement is written down.

The thing to notice is that a cloak host is, in these terms, entirely
`tenant: :none`. Every column it has gives up shreddability, and the migration is
the moment that stops being true for the columns the host declares tenant-scoped.
Deciding which columns those are is a schema-design decision the migration forces
into the open.

## Encrypted columns are not queryable, and never will be

This is the largest behavioural difference from an unencrypted column, and it is
already true on cloak; what changes is that this package refuses to soften it.
The column is `:binary` for every type, whatever the plaintext was (ADR-0001
decision 2), and the ciphertext is non-deterministic - the same plaintext
encrypts to different bytes every time. So there is no equality lookup, no
`LIKE`, no ordering, no unique index, and no `ON CONFLICT` target on an encrypted
column. ADR-0001 decision 10 states that there is no `searchable` option and
there will not be one, and ADR-0003 decision 9 honours the same refusal from the
other side: no prefix search, no range, no `MIN`/`MAX`, no sort, permanently.

The non-determinism has one pleasant side effect worth knowing about, since it
looks like a bug the first time: `equal?/3` compares plaintext (ADR-0001
decision 9). If it compared dumped values, every encrypted field would read as
changed on every write.

## What a blind index restores, and what it does not

A cloak host that needed exact-match lookup almost certainly has a sibling
deterministic column, because that is cloak's own answer to the problem
(ADR-0004's C5). Very often that column is a `Cloak.Ecto.SHA256` - an unsalted,
unkeyed hash of the value.

ADR-0003's context is blunt about what such a column is: not a blind index, but
a public fingerprint that happens to live in a private database. Anyone holding a
dump and no key material at all recovers every value in it whose plaintext comes
from a guessable space, and the columns hosts most want to look up by - email
address, phone number, tax identifier, postal code - are exactly the guessable
spaces. This is why ADR-0004 decision 9 rules that such a column is **replaced,
not supplemented**: adding a keyed index beside an unkeyed one fixes nothing
while the unkeyed one remains. A keyed legacy column - `Cloak.Ecto.HMAC` or
`PBKDF2` - is a different case with a different urgency, and no legacy column at
all is a third. Which one you are in, and in what order the columns are added,
backfilled and dropped, is
[step 7 of the how-to guide](../guides/migrate-from-cloak.md#step-7-replace-the-legacy-lookup-column).

What replaces it is a keyed index. The stored value is an HMAC over a declared
normalization of the plaintext, under a key derived per field and - by default,
for a tenant-scoped field - per tenant (ADR-0003 decisions 1, 2 and 3a; the
derivation itself is that record's, and is where to read it). What that changes
is set out row by row in ADR-0003's security-properties table, which is the
thing to read before adding an index to a column. Three of its consequences are
worth carrying away from this page:

- **Without key material, a known plaintext cannot be confirmed present.** This
  is the security claim the unkeyed folk pattern does not have, and it is the
  second row of ADR-0003's security-properties table.
- **Equality structure stays inside the tenant.** Two tenants storing the same
  email address produce unrelated index bytes, so a dump does not reveal that
  they share a customer - a disclosure across exactly the boundary ADR-0001
  decision 5 spent itself defending.
- **The index shreds with the tenant key.** Destroy the key material and the
  column becomes noise that answers no question, because no candidate value can
  be computed to compare against it (ADR-0003 decision 3b). A `scope: :global`
  index does not inherit that, which is why ADR-0003 decision 3c makes the
  global choice something a host writes out loud rather than falls into.

And what it does not restore. It is **equality only**, over the declared
normalization rather than over the plaintext, so an index hit is not proof of
byte equality (ADR-0003 decision 4). It is a helper the host calls in its own
changesets and queries, not something the type does invisibly - which means,
unlike the encryption, it *can* be forgotten by a second write path, and ADR-0003
names that gap rather than hiding it. Cross-tenant lookup, which a single global
hash column gave for free, now costs a deliberate second index on a deliberately
global field. And the index still publishes the equality structure of its column
inside its scope, permanently, to anyone who ever holds a backup - which is why
ADR-0003 treats the security-properties table as something a host reads *before*
adding an index, not after.

One honest limitation, recorded at ADR-0003's acceptance: computing an index
value requires the tenant's key material, so a component that can search can also
decrypt. The separation between index keys and encryption keys is real and
structural, but it is a key-hierarchy separation, not a capability that can be
handed out on its own today.

## The mixed window is a per-row downgrade while it is open

The migration needs no downtime, and the affordance that makes that true is the
type's `legacy:` option: load through the old type when the primary load fails,
always dump through the new one (ADR-0001 acceptance amendment 4, ADR-0004
decision 4). Ordinary application traffic then migrates rows on its own, because
anything read and written back is written in the new format.

State the cost plainly, because ADR-0004 decision 5 does. **While `legacy:` is
set, a row that has not yet been rewritten is read under the legacy scheme's
rules.** For a cloak host that means those rows have no encryption context, so
the anti-substitution property does not hold for them; and they are under one
key, so per-tenant separation does not hold for them either. The window does not
weaken any *migrated* row. It means the guarantee is per-row until the pass
finishes - and because there is no legacy dump arm, no new legacy-format row can
appear behind it, so the pass finishing is what restores the property. Dropping
`legacy:` afterwards is hygiene rather than the thing that fixes it, which is
why the runbook can leave it to a later step. ADR-0004's Consequences call
this the most dangerous state in the whole design, and it is worth reading that
sentence as written: a host in the window is running two key models over one
column, with the weaker one still authoritative for most rows.

Two things follow that are easy to miss. The window is **per field**: a host with
twelve encrypted columns can finish eleven and still have one legacy reader open,
which is why the design gives the end of the window a signal to detect rather
than a date to remember. And the window has no expiry - nothing in the package
stops a host sitting in it for two years, and ADR-0004's Q5 records that as
unresolved rather than solved. Closing it is a step somebody has to take.

A related asymmetry: `legacy:` is a *load* path and there is no dump arm for it,
ever (ADR-0004 decision 4c). The fallback also does not fire for a missing tenant
or a missing context - those are host misconfiguration, they are loud on purpose,
and answering them with a successful legacy read would convert a configuration
bug into a silent year of un-migrated rows (decision 4a).

## Where reversibility actually ends

Worth knowing before reading the runbook, because the runbook's table and its
prose say different-looking things on purpose. The numbered sequence marks the
write pass as the point of no return, which is where the migration becomes
irreversible *in bulk*. But reversibility ends earlier in practice, at the deploy
that switches the type modules over: from that moment ordinary traffic is writing
new-format rows, and a revert leaves rows the old modules cannot read (ADR-0004
decision 8).

Reverse migration is expressible - the plan's `from:` and `to:` are symmetric, so
a plan with the modules swapped walks the table back - and it is deliberately not
tooled. An automated rollback of a security migration is a mechanism whose only
rehearsal is the emergency it exists for. Its preconditions are the reason the
runbook's last step is last: the legacy key material has to still exist and the
legacy modules have to still be in the tree.

## Reading on

- The runbook, step by step, with the command for each step and what its output
  should say: the how-to guide,
  [migrate a host app off cloak_ecto](../guides/migrate-from-cloak.md), which
  renders ADR-0004 decision 8.
- The flags, the exit codes, and the grammar: the mix tasks' own documentation,
  which is where they live so that they cannot drift from the code that parses
  them.
- The records behind every claim on this page:
  [ADR-0001](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0001-vault-backed-ecto-types.md) for the types, the context
  and tenant resolution; [ADR-0002](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0002-migrator.md) for the migrator;
  [ADR-0003](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0003-blind-index.md) for the blind index and its
  security-properties table; and
  [ADR-0004](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0004-migration-from-cloak.md) for the adoption itself.

There is deliberately no tutorial for this migration, and
[the documentation index](https://github.com/riddler/encryptor_ecto/blob/main/docs/README.md) says why.
