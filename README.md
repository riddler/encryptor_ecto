# Encryptor.Ecto

[![CI](https://github.com/riddler/encryptor_ecto/actions/workflows/ci.yml/badge.svg)](https://github.com/riddler/encryptor_ecto/actions/workflows/ci.yml)
[![Hex.pm Version](https://img.shields.io/hexpm/v/encryptor_ecto.svg)](https://hex.pm/packages/encryptor_ecto)
[![Hex Downloads](https://img.shields.io/hexpm/dt/encryptor_ecto.svg)](https://hex.pm/packages/encryptor_ecto)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/encryptor_ecto/)
[![License](https://img.shields.io/hexpm/l/encryptor_ecto.svg)](https://github.com/riddler/encryptor_ecto/blob/main/LICENSE)

> **Pre-1.0.** Until `encryptor_ecto` reaches v1.0, its public surface may change
> between minor releases, sometimes drastically: a release may rename modules,
> callbacks, table columns, telemetry events or error vocabulary with no
> compatibility shim. Every such change is recorded in
> [CHANGELOG.md](CHANGELOG.md) under a bold **Breaking** heading that says what
> to do about it. Pinning to an exact minor - `~> X.Y.0` - is the recommended way
> to consume the package until 1.0.

Encrypted Ecto types for the [Encryptor](https://github.com/riddler/encryptor)
vault - `cloak_ecto`-shaped field encryption, where an encrypted field is a
type module the schema names like any other type. Changesets, queries, and
`Repo` calls keep their ordinary form; the encryption happens in the type, not
at the call site, and the column changes to `:binary` and nothing else.

What the package ships today:

- **Encrypted field types** - `Encryptor.Ecto.Binary`, `Encryptor.Ecto.String`
  and `Encryptor.Ecto.Map`, with `Integer`, `Float`, `Date`, `Time`,
  `NaiveDateTime` and `DateTime` wrappers over the same machinery, each an
  `Ecto.ParameterizedType` with a closed option set.
- **Scope context, resolved once and fail-closed** - a process-scoped current
  scope, or a host resolver module, with a write that has no scope set
  raising rather than falling back to a default.
- **A migrator for an already-encrypted column** - a compiled plan DSL, and a
  probe-first, compare-and-swap, batched, resumable row rewriter that runs
  against live traffic, with a read-only `verify/2` as its acceptance test.
- **Four `mix` tasks**, thin argument parsers over the library functions, so a
  release without Mix can run the same pass through `eval`.
- **Keyed blind indexes** - salted, per-field and (by default) per-scope HMAC
  derivation, a declaration macro, declared normalizers, and the changeset and
  query helpers that write and read the column.

## The two-package model

There are two packages and they draw one line between them.

**`encryptor` is the vault.** It answers the key-management questions: where
key material comes from, which key a given record's data belongs to, how that
key rotates, and how a scope is crypto-shredded. A host writes one vault
module and starts it in its supervision tree.

**`encryptor_ecto` is this package: the Ecto layer, and nothing else.** It puts
the vault behind a schema field. It has **no key management of its own** - no
provider, no key store, no rotation verb, no shred verb. Its whole task list
contains no operation that touches a key, because re-wrap and crypto-shred
belong to the side that owns the key store (ADR-0002 decision 9).

It also issues no DDL. Every column it reads or writes - the encrypted
`:binary` column, the blind index column, the migrator's checkpoint table - is
created by the host's own migration on the host's own deploy schedule.

Stored bytes are the vault's format, verbatim: this layer adds no envelope, no
version prefix, and no magic bytes (ADR-0001 decision 11). Runtime
dependencies are `ecto`, the vault, `jason` (the default serializer for the map
type, replaceable with any module exporting `encode!/1` and `decode!/1`), and
`telemetry`.

## Installation

```elixir
def deps do
  [
    {:encryptor_ecto, "~> 0.5.0"}
  ]
end
```

Read the changelog before upgrading: the pre-1.0 banner at the top of this
file is the stability claim, and it says what a release may change and how to
pin against it. **Do not depend on the 0.1.0 versions** - `encryptor_ecto 0.1.0`
and `encryptor 0.1.0` are name reservations that predate the API this README
describes; 0.2.0 is the first release of either package that holds the
implementation.

Add the formatter import so the paren-free declaration macros are not
rewritten:

```elixir
# .formatter.exs
import_deps: [:ecto, :encryptor_ecto]
```

## Quickstart

The worked domain below is card processing.

**1. A vault, started in the supervision tree.** This is the `encryptor` half.
Key material arrives through `init/1`; passing it at `use` is a compile-time
error.

```elixir
defmodule Payments.Vault do
  use Encryptor.Vault,
    otp_app: :payments,
    context_profile: :scoped,
    required_context: ["table", "column"]

  def init(config) do
    {:ok, Keyword.merge(config, provider: Payments.Keys.provider())}
  end
end
```

**2. One type module per encrypted type**, naming that vault. `:vault` is
required and has no application-environment fallback: it is named at the
declaration or the module does not compile.

```elixir
defmodule Payments.Encrypted.Binary do
  use Encryptor.Ecto.Binary, vault: Payments.Vault
end

defmodule Payments.Encrypted.String do
  use Encryptor.Ecto.String, vault: Payments.Vault
end
```

The full closed option set is `:vault` (required), `:scope` (`:process` by
default, `:none`, or an `Encryptor.Ecto.ScopeContext` module), `:context`,
`:legacy`, and the `:table` / `:column` context pins - plus `:json` on
`Encryptor.Ecto.Map`, which defaults to `Jason`. An unknown option raises while
the host module compiles, and two fields sharing one declared
`{table, column}` pair could decrypt each other's bytes, which is what
`Encryptor.Ecto.Declarations.check_unique!/1` checks at application start.

**3. The schema names the type like any other type.** The column is `:binary`.

```elixir
defmodule Payments.Cards.Card do
  use Ecto.Schema

  schema "cards" do
    field :merchant_id, :string
    field :pan, Payments.Encrypted.Binary
    field :notes, Payments.Encrypted.String
  end
end
```

`"table"` and `"column"` are derived from the schema once, at declaration time,
and bound into every message as additional authenticated data, so a ciphertext
lifted out of one row and dropped into another fails authentication rather than
decrypting into the wrong place. Because they are frozen at declaration, a
physical rename costs nothing - pin the old strings with `:table` / `:column`
and stored rows stay readable.

**4. Set the scope at the edge of every unit of work.** Scope does
not propagate across processes, and this package does not pretend it does.

```elixir
Encryptor.Ecto.Scope.put("merchant_7f3")

# crossing into a process that did not inherit it
scope = Encryptor.Ecto.Scope.fetch!()
Task.async(fn -> Encryptor.Ecto.Scope.wrap(scope, &settle_batch/0) end)
```

A write with no scope set raises `Encryptor.Ecto.MissingScopeError`
rather than falling back to a default. That fires first in a host's own test
suite, which is what `Encryptor.Ecto.ScopeSetup` ships for:

```elixir
defmodule Payments.CardsTest do
  use ExUnit.Case, async: true
  import Encryptor.Ecto.ScopeSetup

  setup_scope "merchant_7f3"

  test "stores a card under the merchant in scope" do
    assert {:ok, _card} = Payments.Cards.store(%{pan: "4111111111111111"})
  end
end
```

`nil` dumps and loads as `nil` with no encryption, so `is_nil` queries keep
working. An empty binary is not `nil` and is encrypted. `dump/3` and `load/3`
have no `:error` arm at all: an infrastructure or integrity failure raises
rather than surfacing as a validation error a changeset could proceed past.

## Exact-match lookup: blind indexes

Encrypted columns are not queryable, sortable, or uniquely indexable, and there
is no `searchable` option - no `LIKE`, no prefix search, no range, no ordering,
permanently. Equality lookup is served by a separate keyed blind index with its
own key derivation and its own documented leakage.

The index column is the host's own, declared in the host's own migration. The
declaration puts its normalization and its key derivation in one place so the
write helper and the read helper cannot disagree:

```elixir
defmodule Signups.Signup do
  use Ecto.Schema
  import Encryptor.Ecto.BlindIndex

  schema "signups" do
    field :merchant_id, :string
    field :variant, :string

    field :email, Signups.Encrypted.String
    field :email_index, :binary
    blind_index :email, :email_index, normalize: :email
  end
end
```

```elixir
def changeset(signup, attrs) do
  signup
  |> cast(attrs, [:email, :variant])
  |> Encryptor.Ecto.BlindIndex.put_index(:email, :email_index)
end

def by_email(email) do
  Signups.Signup
  |> Encryptor.Ecto.BlindIndex.where_eq(:email, email)
  |> Repo.one()
end
```

Options are `:name` (defaults to the index column's name), `:derive`
(`:per_scope` by default, or `:global`), `:normalize` (`:none` by default; the
built-ins are `:none`, `:trim`, `:downcase`, `:email` and `:digits`, or a
`{module, function}` pair), `:bits` (`256` by default; `64`, `128` and `192`
truncate the stored value), `:version` (`1` by default) and `:slow`. An index
on a `scope: :none` field has to write `derive: :global` out loud - declaring
nothing there is a compile-time error rather than a silent fallback, because a
global index's equality structure survives a scope's crypto-shred.

Four things are worth knowing before adding one:

- **The index is a call-site helper, not something the type does invisibly.**
  Encryption cannot be forgotten; the index can. A bulk insert or a second
  changeset function that skips `put_index/3` writes a row whose lookup
  silently misses.
- **On a truncated index the read helper is `where_eq_candidates/3`**, not
  `where_eq/3`. It returns a candidate set to filter after decrypting, and
  `where_eq/3` refuses a truncated declaration outright - the name is the
  contract, so a call site cannot forget. `where_eq/4` and
  `where_eq_candidates/4` name the index column explicitly, which is what a
  field carrying two declarations (a `:version` rotation window, or a full and
  a narrow index) requires.
- **It is equality only**, over the declared normalization rather than over the
  plaintext, so a hit is not proof of byte equality.
- **A rotation is a reindex.** The key is derived through the vault under a
  per-deployment `:derivation_salt` - the vault's option, never supplied by
  this package, and what stops a restored backup or a cloned staging database
  from being joined against production - and an `info` string binding the
  table, the column, the index name and the `:version`. Changing `:normalize`,
  `:bits` or `:version`, rotating the `:derivation_salt`, or rotating a
  scope's key material each invalidates every stored value in the column, and
  recomputing them needs decrypted plaintext. Treat the salt as permanent from
  the first stored index value; the scope-key case has no supported rotation
  sequence today.

`:slow` runs **Argon2id over the normalized value before the HMAC**, which is
the low-entropy column's only defence here: an attacker holding the index key
still recovers a guessable column, but at one Argon2id hash per candidate
rather than one HMAC. The parameters are the vault's frozen `:slow_hash`
configuration and never this package's, and the salt is derived per index, per
scope and per deployment through the same vault call the index key comes from
(ADR-0003 amendment C). Two things follow: a `slow: true` index whose vault
declares no `:slow_hash` raises rather than quietly writing plain-cost bytes,
and a host declaring one adds `:argon2_elixir` to its own dependencies - the
NIF is not this package's.

The full leakage table - what an attacker learns from a dump, from a dump plus
one scope's index key, and from a retained dump after a shred - is
`Encryptor.Ecto.BlindIndex`'s *Security properties* section, and it is meant to
be read before declaring an index rather than after.

## Migrating a column that is already encrypted

For a field already encrypted through `cloak_ecto` or a hand-rolled type, both
formats are bytes in the `:binary` column that already exists, so the move is a
data migration rather than a schema one: the type modules change, the schemas
do not, and the rewrite runs against live traffic.

Adding `legacy:` to the type module opens the mixed window - the new load is
attempted first, always, and the legacy module is tried only when the new one
fails with a message-shaped failure. It is never a write path, so ordinary
traffic migrates rows on its own from that deploy. A
`[:encryptor_ecto, :legacy_load]` telemetry event, carrying the table and the
column and nothing else, is how a host watches the window close.

The bulk rewrite is a plan the host writes, reviews in a diff, and deletes when
the window closes:

```elixir
defmodule Payments.Encryption.CloakMigration do
  use Encryptor.Ecto.Migration, repo: Payments.Repo

  rewrite Payments.Cards.Card do
    scope_from :merchant_id

    field :pan,
      from: Payments.Cloak.Encrypted.Binary,
      to: Payments.Encrypted.Binary,
      source_authenticated: true
  end
end
```

The DSL is compile-checked against the real schemas: every `field`, every
`into:` and every `scope_from` column has to exist, every `from:` module has
to be able to load the stored bytes, and every `to:` module has to both load
and dump. `source_authenticated:` is required on every field whose `from:` is
not one of this package's own vault-backed types, and it is an
**acknowledgement, not a capability flag** - writing `false` (a legacy cipher
that cannot fail a decrypt on wrong bytes, such as `Cloak.Ciphers.AES.CTR`)
counts those rows `:migratable_unverified` in every mode and makes
`mode: :write` refuse outright, before a row is visited, unless a host
`validate:` predicate is declared beside it.

```elixir
Encryptor.Ecto.Migrator.run(Payments.Encryption.CloakMigration, mode: :dry_run)
Encryptor.Ecto.Migrator.run(Payments.Encryption.CloakMigration, mode: :write)
Encryptor.Ecto.Migrator.verify(Payments.Encryption.CloakMigration, sample: :all)
```

There is no default `:mode`; a missing one is an `ArgumentError` rather than a
dry run. A dry run performs every read, probe, decrypt and encrypt and discards
the write, so it is an exact rehearsal including how long it takes. Rows are
visited in primary-key order with keyset pagination (never `OFFSET`), every row
is probed before it is rewritten so the pass is idempotent by construction,
every write is a compare-and-swap against the exact bytes that were read so a
row the application wrote in the meantime is counted rather than clobbered, and
each batch is one transaction with the checkpoint row written inside it.
`:batch_size`, `:resume`, `:prefix`, `:checkpoint`, `:on_error`,
`:only_scopes`, `:except_scopes`, `:only` and `:progress` are the options.

Both arms return a report. Rows are classified `:null`, `:already_target`,
`:migratable`, `:migratable_unverified` or `:undecryptable`, with `concurrent`
counted separately - those are rows the application rewrote between the read
and the write, left alone rather than clobbered. `verify/2` is deliberately
stricter than the pass: it returns `{:ok, report}` only when every row it saw
was `:already_target` or `:null`. Failures record the schema, the field, the
row id and a reason, and never plaintext, ciphertext or key material.

The same functions are reachable as `mix` tasks, because a production host runs
releases and a release has no Mix - the library function is the interface and
the tasks are thin parsers over it:

| Task | What it does |
|---|---|
| `mix encryptor.ecto.gen.plan` | Writes a migration plan skeleton for a human to finish |
| `mix encryptor.ecto.gen.migration` | Writes the checkpoint table's migration into the host's tree |
| `mix encryptor.ecto.migrate` | Rewrites the ciphertext columns a plan names |
| `mix encryptor.ecto.verify` | Checks whether a plan's rows are all in the target state |

Their flag tables, exit codes and grammar are their own `@moduledoc`s - read
them with `mix help encryptor.ecto.migrate` and friends.
`Encryptor.Ecto.Migrator.Census` renders the cheap SQL half of verification as
text an operator pastes into `psql`, with no repository, no application and no
key.

Adopting encryption on a column that was **never** encrypted is not that case:
plaintext lives in a text column and ciphertext must live in a binary one, so
it is an expand, backfill and contract across two columns and two deploys, and
the backfill leg is the only part of that dance the migrator performs.

## Documentation

The pages under [`docs/`](https://github.com/riddler/encryptor_ecto/blob/main/docs/README.md) are organized by
[Diataxis](https://diataxis.fr) quadrant. The three pages below ship with the
package documentation - `mix.exs`'s `docs()` lists them as extras, so they are
on HexDocs beside the module documentation and link to each other by relative
path. The index is not an extra and links at its GitHub path:

- [`docs/README.md`](https://github.com/riddler/encryptor_ecto/blob/main/docs/README.md) - the index, including why there is
  deliberately no tutorial. Repository-only; it is not published to HexDocs.
- [What changes when you move off cloak_ecto](docs/explanation/moving-off-cloak.md) -
  per-scope keys where cloak had one, the encryption context and the
  substitution it forbids, fail-closed scope and the boundary audit that
  is the real cost of adoption, crypto-shredding, why encrypted columns are not
  queryable, and what a blind index does and does not restore.
- [How to migrate a host app off cloak_ecto](docs/guides/migrate-from-cloak.md) -
  the nine-step runbook, each step in both release `eval` and `mix` form, with
  the expected output, what to do when it differs, the disposition of a legacy
  lookup column, and where reversibility actually ends.
- [How to bind extra identifiers into an encrypted field's context](docs/guides/bind-extra-context.md) -
  what belongs in a declared `:context` and what does not, how the pairs
  compose, which refusals a declaration buys, and why a bound value is
  permanent.
- [How to keep scope keys in Google Cloud KMS through the key store](docs/guides/gcp-kms-key-store.md) -
  the Goth token server, the key store's `:gcp_kms` option, provisioning a
  `"gcp_kms_ciphertext"` row, and the shred: destroying the key version,
  deleting the row, the restore window, and what the application sees in
  between.
- [Two vaults: a customer scope and an agreement scope](docs/guides/two-vaults-customer-and-agreement.md) -
  a customer vault for platform data and credentials beside an agreement
  vault for data shared under a data agreement: the two key tables, the
  process resolver and a resolver fed from the row, and the shred of one
  agreement, with what each vault's shred reaches.
- [Resolving the scope in jobs and projectors](docs/guides/scope-in-jobs-and-projectors.md) -
  why the scope stops at the process, carrying it into a `Task` with
  `Encryptor.Ecto.Scope.wrap/2`, into a background job through its
  arguments, and into an event projector through a resolver the projector
  feeds from each event.

Reference material is the module documentation: `Encryptor.Ecto.Binary`,
`Encryptor.Ecto.BlindIndex`, `Encryptor.Ecto.Migration`,
`Encryptor.Ecto.Migrator` and the four task modules each carry their own.

## Records

The contracts are decided in ADRs before they are coded. A cryptographic choice
made inline in an implementation commit is a defect here even when the choice
happens to be a good one, because the record is what makes it reviewable.

| # | Decision | Status |
|---|---|---|
| [ADR-0001](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0001-vault-backed-ecto-types.md) | The types, the closed option set, the encryption context, scope resolution | accepted, with amendments |
| [ADR-0002](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0002-migrator.md) | The migrator: plan-driven, probe-first, compare-and-swap, live traffic | accepted, with amendments |
| [ADR-0003](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0003-blind-index.md) | Keyed blind indexes, per-scope by default, equality only | accepted, with amendments |
| [ADR-0004](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0004-migration-from-cloak.md) | Adoption: the migration runbook, the task family, the mixed window | accepted, with amendments |

Every amendment the four records carry was accepted by the operator's
reading of 2026-09-13; each says what it changes, and the decision text above
it is unchanged.

## License

Apache-2.0 - see
[LICENSE](https://github.com/riddler/encryptor_ecto/blob/main/LICENSE).
