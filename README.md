# Encryptor.Ecto

[![CI](https://github.com/riddler/encryptor_ecto/actions/workflows/ci.yml/badge.svg)](https://github.com/riddler/encryptor_ecto/actions/workflows/ci.yml)
[![Hex.pm Version](https://img.shields.io/hexpm/v/encryptor_ecto.svg)](https://hex.pm/packages/encryptor_ecto)
[![Hex Downloads](https://img.shields.io/hexpm/dt/encryptor_ecto.svg)](https://hex.pm/packages/encryptor_ecto)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/encryptor_ecto/)
[![License](https://img.shields.io/hexpm/l/encryptor_ecto.svg)](https://github.com/riddler/encryptor_ecto/blob/main/LICENSE)

Encrypted Ecto types for the [Encryptor](https://github.com/riddler/encryptor)
vault - `cloak_ecto`-shaped field encryption, where turning a plaintext column
into an encrypted one is a two-line migration and a one-word schema change.

**Status: scaffold.** Nothing is implemented yet. The package skeleton is in
place; the contracts below are being decided in ADRs before any of them is
built.

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
  in the type, not at the call site.

- **A two-line migration.** Adopting encryption on an existing field is a
  column type change to `:binary` and a backfill. There is no new table, no
  companion column, and no shadow schema - which is the whole positioning of
  the package. Ciphertext carries the AWS Encryption SDK message format the
  vault produces, key identity included, so the column is self-describing and
  rotation does not need a flag day.

- **Tenant context, resolved once.** A multi-tenant host app needs each
  tenant's rows encrypted under that tenant's own key. Which tenant a value
  belongs to is resolved by a declared strategy the type reads, rather than
  being threaded through every changeset by hand.

The vault stays `Encryptor`. This package wraps it for the Ecto layer only; it
adds no key management of its own and no dependency beyond Ecto and the vault.

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

MIT - see
[LICENSE](https://github.com/riddler/encryptor_ecto/blob/main/LICENSE).
