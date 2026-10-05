# Why the Ecto types are a second package

Field encryption over the Encryptor vault comes as two packages: `encryptor`,
the vault, and `encryptor_ecto`, the Ecto layer this documentation describes.
A host that encrypts Ecto columns depends on both, writes one vault module and
one type module per encrypted type, and could reasonably ask why that is not
one dependency. This page is about where the line between the two falls, why
it falls there, and what the split costs.

## Two questions, two packages

The vault answers the key-management questions: where key material comes
from, which key a given value belongs to, how that key rotates, and how a
scope is crypto-shredded. It takes a plaintext and an encryption context and
gives back a ciphertext, and the reverse. Nothing in that answer mentions a
database.

This package answers a different question: how a value reaches the vault from
a schema field and comes back, with nobody at the call site remembering to do
it. Its parts are the field types, the scope resolution that decides which key
a written value belongs to, the keyed blind indexes beside an encrypted
column, the migrator that rewrites an already-encrypted column under live
traffic, and the stores that keep what the vault needs inside the host's own
repo: `Encryptor.Ecto.KeyStore`, a key provider over a wrapped-key table, and
`Encryptor.Ecto.SuspensionStore`, where a suspension is shared across nodes.

The two questions change for different reasons. A new key provider, a new
algorithm suite or a new rotation level is a vault change, and it matters to
every host whatever it stores ciphertext in. A new Ecto type, a different way
of resolving the scope or a change to the migrator's checkpoint table is a
change here, and it matters only to a host whose ciphertext lives in Ecto
columns.

## The seam test

The migrator's decision record states the line as one test: if an operation
would still be needed by a host that stores its ciphertext somewhere other
than Ecto, it is not this package's
([ADR-0002](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0002-migrator.md),
decision 9).

Key creation and re-wrap would still be needed, so they stay in the vault: a
host keeping ciphertext in object storage or a message log needs them just as
much. This package's task list therefore contains no verb that operates on a
key. Walking rows, rewriting a column and checkpointing a pass would not, so
they live here: the vault's own rekey is a pure binary-to-binary function that
touches no storage, and the batch that walks rows is this package's.

Storage itself falls on this side for the same reason. The vault defines no
table, migration, repo, primary key, index or transaction; it produces and
consumes wrapped-key structs and leaves where they are kept to whoever owns
the storage
([the vault's ADR-0003](https://github.com/riddler/encryptor/blob/main/docs/adr/0003-per-tenant-envelope.md),
decision 9). The Ecto-backed key provider lives here because it owns a schema,
a migration and a repo, and the vault owns only the behaviour it implements
([the vault's ADR-0002](https://github.com/riddler/encryptor/blob/main/docs/adr/0002-key-providers.md),
decision 5). The row delete a crypto-shred ends in is `KeyStore.shred/3` for
that reason: the row is in a table this package defines.

Even on this side the line stops short of the database schema. This package
issues no DDL at runtime or from a task: the encrypted `:binary` column, a
blind index column, the migrator's checkpoint table and the stores' tables all
arrive through the host's own migrations, on the host's own deploy schedule.
For the tables this package defines, its generators write migration source
into the host's tree for the host to read and apply.

## The alternatives

**One package, with Ecto as a required dependency.** The simplest shape for a
host that uses Ecto, and the wrong one for every host that does not. The vault
is useful without a database layer at all: it encrypts a message payload or a
file just as well as a column. Making Ecto a hard dependency of the vault would
put a database library in the tree of every such host, and would make every
change to the Ecto layer a release of the vault.

**One package, with Ecto as an optional dependency.** This is the usual Elixir
answer to "some hosts need it", and the vault does use it, for the native
Argon2 library and for the Google Cloud token server. Those are leaves: one
function or one provider each, and a host that does not configure them carries
nothing. The Ecto layer is not a leaf. It is most of a package - nine field
types, a scope model, the blind index, a migrator with its own plan language
and mix tasks, two stores with their tables - and compiling all of it
conditionally means two builds of the vault with different surfaces. The
vault's own record on telemetry makes the same argument from the other
direction: an optional dependency buys two builds with different
observability, and the un-observed one is the build in production
([the vault's ADR-0006](https://github.com/riddler/encryptor/blob/main/docs/adr/0006-telemetry-and-observability.md),
decision 1). There it kept the dependency hard; here, where the dependency is
large and many hosts never need it, the same reasoning moves it into its own
package.

**No Ecto layer at all, and hosts write the glue.** The vault would stay
small and every host would write its own `Ecto.Type` around it. That glue is
where field encryption usually goes wrong: the cast, load and dump arms
disagree about `nil`, the ciphertext lands in a column nobody widened, the
scope is resolved a slightly different way at every call site, and a write
with no scope quietly falls back to a default key. Writing it once, with the
scope resolved by a declared strategy and a write with no scope refused, is
the reason this package exists.

**The established split, kept.** The Elixir ecosystem already separates a
cipher library from its Ecto types: `cloak` and `cloak_ecto` are two packages,
and a host on them already has a module per encrypted type that names a vault.
Keeping the same split, and the same type-module shape, is part of why moving
off `cloak_ecto` changes the type modules and leaves the schemas alone
([ADR-0001](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0001-vault-backed-ecto-types.md),
context). What changes when a host moves is discussed in
[What changes when you move off cloak_ecto](moving-off-cloak.md).

## What the split costs

Two packages are two versions to keep in step. This package pins the vault
exactly, `encryptor == 0.6.0`, rather than to a range: before 1.0 the vault
may change what stored bytes mean between releases, and a range would let a
host's dependency update change the meaning of rows already written. The pin
widens only when the vault's guarantees do, which means a vault release
reaches an Ecto host only after a release of this package that names it.

The contract between the two is also a public one. This package reaches the
vault only through its public, documented modules - the vault module, the
key-provider behaviour, the envelope functions - and stores the vault's bytes
verbatim, with no envelope, version prefix or magic bytes of its own
([ADR-0001](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0001-vault-backed-ecto-types.md),
decision 11). That keeps the layer honest - it cannot reach into the vault's
internals - and it means a vault contract that looks wrong from the Ecto side
is raised and changed in the vault, not worked round here. An Ecto type that
quietly wrote a ciphertext shape the vault does not accept would be exactly
the failure the separation is meant to make visible.

And a host reads two sets of documentation. The vault's covers keys,
providers, rotation and the shred procedures; this package's covers fields,
scopes, indexes and migrations. The split in the documentation follows the
split in the code, so a question about which key a value is under goes to the
vault's pages, and a question about how a field gets that value to the vault
comes here.

## Reading on

- [What the package ships, and what it leaves to the vault](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.html):
  the package overview, one paragraph per part.
- [The vault's documentation](https://hexdocs.pm/encryptor): key providers,
  rotation, suspension and the shred.
- [The decision records](https://github.com/riddler/encryptor_ecto/tree/main/docs/adr):
  the reasoning behind each part of this package, including the seam above.
