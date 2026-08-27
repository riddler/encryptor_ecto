# Encryptor.Ecto

[![CI](https://github.com/riddler/encryptor_ecto/actions/workflows/ci.yml/badge.svg)](https://github.com/riddler/encryptor_ecto/actions/workflows/ci.yml)
[![Hex.pm Version](https://img.shields.io/hexpm/v/encryptor_ecto.svg)](https://hex.pm/packages/encryptor_ecto)
[![Hex Downloads](https://img.shields.io/hexpm/dt/encryptor_ecto.svg)](https://hex.pm/packages/encryptor_ecto)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/encryptor_ecto/)
[![License](https://img.shields.io/hexpm/l/encryptor_ecto.svg)](https://github.com/riddler/encryptor_ecto/blob/main/LICENSE)

Encrypted Ecto types for the [Encryptor](https://github.com/riddler/encryptor)
vault - `cloak_ecto`-shaped field encryption, where a schema field is declared
encrypted once and every read and write in the application goes through the
vault without the calling code knowing.

**Status: design phase. Nothing is implemented yet.** The package holds a
skeleton and a set of records. The contracts are being decided in ADRs first,
on purpose: a blind-index construction, an encryption-context field, or a
ciphertext layout chosen inline in an implementation commit is a defect here
even when the choice happens to be a good one, because the record is what
makes it reviewable.

| Record | Status | Subject |
|---|---|---|
| [ADR-0001](docs/adr/0001-vault-backed-ecto-types.md) | accepted, with amendments | The types, the closed option set, the encryption context, tenant resolution |
| [ADR-0002](docs/adr/0002-migrator.md) | accepted | The migrator: plan-driven, probe-first, compare-and-swap, live traffic |
| [ADR-0003](docs/adr/0003-blind-index.md) | accepted, with one amendment | Keyed blind indexes, per-tenant by default, equality only |
| [ADR-0004](docs/adr/0004-migration-from-cloak.md) | proposed | Adoption: the migration runbook, the task family, the mixed window |

The implementation graph derived from them is
[`docs/plans/260827-ece-wdm-c3-implementation-graph.md`](docs/plans/260827-ece-wdm-c3-implementation-graph.md).

Everything below describes what the accepted records decide, not a shipped
API. Nothing here is a compatibility promise until it exists and is released.

## The charter

Encryptor answers the key-management questions: where key material comes from,
which key a given record's data belongs to, and how that key rotates. What it
does not do is put any of that behind a schema field. Hand-rolling that glue
is where application-level encryption usually goes wrong - the cast, load, and
dump arms disagree about `nil`, the ciphertext lands in a column nobody
remembered to widen, and the tenant a value belongs to gets resolved a
slightly different way at every call site.

This package is that glue, in the shape Ecto already expects:

- **Encrypted field types.** An encrypted field is an `Ecto.Type` module, so
  a schema declares it the way it declares any other type. Changesets,
  queries, and `Repo` calls keep their ordinary form; the encryption happens
  in the type, not at the call site. The column is `:binary`, always.

- **Anti-substitution by construction.** Every value is encrypted under an
  encryption context that identifies the tenant, the table, and the column,
  bound into the message as additional authenticated data. A ciphertext
  lifted out of one row and dropped into another fails authentication rather
  than decrypting into the wrong place, and a host cannot forget to supply
  the context because it never supplies it.

- **Tenant context, resolved once, and fail-closed.** A multi-tenant host app
  needs each tenant's rows encrypted under that tenant's own key. Which
  tenant a value belongs to is resolved by a declared strategy the type
  reads, rather than being threaded through every changeset by hand - and a
  write with no tenant in scope raises rather than falling back to a default.
  The cost of that is real and is named in ADR-0001: adopting this package
  means auditing the boundaries where a unit of work begins.

- **A migration that needs no downtime.** For a host already encrypting
  through `cloak_ecto` or a hand-rolled type, both formats are bytes in the
  `:binary` column that already exists, so the move is a data migration
  rather than a schema one: the type modules change, the schemas do not, and
  the rewrite runs against live traffic. Adopting encryption on a column that
  was never encrypted is *not* that case - plaintext lives in a text column
  and ciphertext must live in a binary one, so it is an expand, backfill, and
  contract across two columns and two deploys.

- **Exact-match lookup, and nothing that pretends to be more.** Encrypted
  columns are not queryable, sortable, or uniquely indexable, and there is no
  `searchable` option. Equality lookup is served by a separate keyed blind
  index with its own key derivation and its own documented leakage. There is
  no `LIKE`, no prefix search, no range, and no ordering - permanently.

The vault stays `Encryptor`. This package wraps it for the Ecto layer only; it
adds no key management of its own and no dependency beyond Ecto and the vault.
It issues no DDL, and its task list contains no verb that operates on a key:
rotating the key-encrypting key and crypto-shredding a tenant are the vault's
operations, not this package's.

## Installation

```elixir
def deps do
  [
    {:encryptor_ecto, "~> 0.1"}
  ]
end
```

Not yet published to Hex. `encryptor` is not published yet either, so during
bootstrap the vault dependency is pinned to a git SHA rather than a Hex
version.

## License

Apache-2.0 - see
[LICENSE](https://github.com/riddler/encryptor_ecto/blob/main/LICENSE).
