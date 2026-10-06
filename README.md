# Encryptor.Ecto

[![CI](https://github.com/riddler/encryptor_ecto/actions/workflows/ci.yml/badge.svg)](https://github.com/riddler/encryptor_ecto/actions/workflows/ci.yml)
[![Hex.pm Version](https://img.shields.io/hexpm/v/encryptor_ecto.svg)](https://hex.pm/packages/encryptor_ecto)
[![Hex Downloads](https://img.shields.io/hexpm/dt/encryptor_ecto.svg)](https://hex.pm/packages/encryptor_ecto)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/encryptor_ecto/)
[![License](https://img.shields.io/hexpm/l/encryptor_ecto.svg)](https://github.com/riddler/encryptor_ecto/blob/main/LICENSE)

Encrypted Ecto types over the [Encryptor](https://github.com/riddler/encryptor)
vault, for Elixir developers whose columns must be encrypted at rest. A schema
names an encrypted field's type like any other type, so changesets, queries and
`Repo` calls keep their ordinary form. Beside the types are keyed blind indexes
for equality lookup, a key store for the vault's wrapped keys, and a migrator
that rewrites an already-encrypted column under live traffic.

## Why this package

The vault decides where key material comes from, which key a record's data
belongs to and how that key rotates, but it puts none of that behind a schema
field, and hand-written glue is where field encryption usually goes wrong: the
cast, load and dump arms disagree about `nil`, the ciphertext lands in a column
nobody widened, the key a value belongs to is resolved a slightly different way
at every call site, and a write with no key in scope quietly falls back to a
default. With this package that glue is one type module per encrypted type: the
scope is resolved once by a declared strategy, a write with no scope raises
instead of choosing a key, the table and column are bound into every ciphertext
so a value copied into another column fails to decrypt, and the stored bytes
are the vault's own format, verbatim. Where the line between the vault and this
layer falls is in the
[package overview](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.html).

## Installation

```elixir
def deps do
  [
    {:encryptor_ecto, "~> 0.8.0"}
  ]
end
```

Add the formatter import so the paren-free declaration macros are not
rewritten:

```elixir
# .formatter.exs
import_deps: [:ecto, :encryptor_ecto]
```

## Basic usage

A vault, one type module naming it, and a schema with one encrypted field:

```elixir
# The vault answers the key questions. Its key provider arrives when it
# starts (application config or `init/1`), never as a `use` option.
defmodule MyApp.Vault do
  use Encryptor.Vault,
    otp_app: :my_app,
    context_profile: :scoped,
    required_context: ["table", "column"]
end

# One module per encrypted type; `:vault` is required.
defmodule MyApp.Encrypted.String do
  use Encryptor.Ecto.String, vault: MyApp.Vault
end

# The schema names the type like any other. The column is `:binary`.
defmodule MyApp.Note do
  use Ecto.Schema

  schema "notes" do
    field :owner_id, :string
    field :body, MyApp.Encrypted.String
  end
end

defmodule MyApp.Notes do
  # Set the scope at the edge of each unit of work: it names the key the
  # value is encrypted under, and a write without one raises.
  def create(repo, owner_id, body) do
    Encryptor.Ecto.Scope.put(owner_id)
    repo.insert(%MyApp.Note{owner_id: owner_id, body: body})
  end
end
```

## Documentation

- Learn
  - [Basic usage](#basic-usage): a vault, a type module and a schema with one encrypted field, written with a scope set.
- Do
  - [How to migrate a host app off cloak_ecto](docs/guides/migrate-from-cloak.md): the runbook step by step, each command in release `eval` and `mix` form, with the output to expect.
  - [How to bind extra identifiers into an encrypted field's context](docs/guides/bind-extra-context.md): what belongs in a declared `:context`, how the pairs compose, and why a bound value is permanent.
  - [How to keep scope keys in Google Cloud KMS through the key store](docs/guides/gcp-kms-key-store.md): the token server, the key store's `:gcp_kms` option, provisioning a row and the shred.
  - [How to keep a customer scope and an agreement scope in two vaults](docs/guides/two-vaults-customer-and-agreement.md): two key tables, a process resolver beside a resolver fed from the row, and the shred of one agreement.
  - [How to resolve the scope in jobs and projectors](docs/guides/scope-in-jobs-and-projectors.md): carrying the scope into a `Task`, a background job and an event projector.
  - [Declare and query a blind index](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.BlindIndex.html): the declaration, its options and the two query helpers, in the API reference until a guide page exists.
- Look up
  - [The field types](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.Binary.html): the closed option set, the encryption context, `nil`, failures and the `:legacy` window.
  - [What a blind index leaks](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.BlindIndex.html#module-security-properties): what a dump, a dump plus one scope's index key, and a retained dump after a shred each reveal.
  - [The scope](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.Scope.html): setting it, wrapping work that crosses a process, and the boundaries a host wraps.
  - [The migration plan](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.Migration.html): the plan DSL and the compile-time checks it makes against the real schemas.
  - [The migrator](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.Migrator.html): one pass, its modes and options, and the report it returns.
  - [The migrate task](https://hexdocs.pm/encryptor_ecto/Mix.Tasks.Encryptor.Ecto.Migrate.html): its flags and exit codes; the other tasks are listed beside it in the sidebar.
  - [The key store](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.KeyStore.html): configuring it, its table and its failure vocabulary.
  - [The changelog](https://github.com/riddler/encryptor_ecto/blob/main/CHANGELOG.md): what changed in each version, with every breaking change marked.
- Understand
  - [Why the Ecto types are a second package](docs/explanation/why-a-second-package.md): where the line between the vault and this package falls, the alternatives to two packages, and what the split costs.
  - [What changes when you move off cloak_ecto](docs/explanation/moving-off-cloak.md): per-scope keys, the encryption context, fail-closed scope, crypto-shredding, and what a blind index restores.
  - [What the package ships, and what it leaves to the vault](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.html): the types, scope resolution, blind indexes, the migrator and the key store in one page.
  - [The decision records](https://github.com/riddler/encryptor_ecto/tree/main/docs/adr): why the types, the migrator, the blind index and the key store are shaped the way they are.

## Compatibility

The package needs Elixir 1.18 or later (`elixir: "~> 1.18"` in `mix.exs`). Its
runtime dependencies are `ecto ~> 3.13`, `jason ~> 1.4` (the default
serializer for `Encryptor.Ecto.Map`, replaceable with any module exporting
`encode!/1` and `decode!/1`), `telemetry ~> 1.0`, and the vault pinned
exactly, `encryptor == 0.7.0`: the vault may change what stored bytes mean
between its pre-1.0 releases, so the pin widens only when its guarantees do. A
blind index declared `slow: true` also needs `argon2_elixir` in the host's own
dependencies. CI runs the full gate on Erlang/OTP 27 and the test suite on
Erlang/OTP 26, both with Elixir 1.18.

Until 1.0, the public surface may change between minor releases: a release may
rename modules, callbacks, table columns, telemetry events or error vocabulary
with no compatibility shim. Every such change is recorded in the
[changelog](https://github.com/riddler/encryptor_ecto/blob/main/CHANGELOG.md)
under a bold **Breaking** heading that says what to do about it, and pinning
to an exact minor, `~> X.Y.0`, is the recommended way to take the package
until then.

## License

Apache-2.0 - see
[LICENSE](https://github.com/riddler/encryptor_ecto/blob/main/LICENSE).
