defmodule Encryptor.Ecto do
  @moduledoc """
  Encrypted Ecto types for the [Encryptor](https://github.com/riddler/encryptor)
  vault - `cloak_ecto`-shaped field encryption for Ecto schemas.

  Encryptor answers where key material comes from and which key a given
  record's data belongs to. What it does not do is put that behind a schema
  field, and hand-rolling the glue is where field encryption usually goes
  wrong: the ciphertext ends up in a column nobody remembers to widen, the
  cast/load/dump arms disagree about `nil`, and the tenant a value belongs to
  is resolved differently at every call site.

  This package is that glue, in the shape Ecto already expects. Encrypted
  fields are `Ecto.Type` modules a schema declares like any other type, so the
  changeset, the query, and the migration all keep their ordinary form, and
  the column changes to `:binary` and nothing else.

  ## What the package ships

  - **The field types.** `Encryptor.Ecto.Binary`, `Encryptor.Ecto.String` and
    `Encryptor.Ecto.Map` (ADR-0001 decisions 1 and 8). The latter two call
    `Binary` rather than copying it, so the closed option set, the declared
    `"table"`/`"column"` encryption context, the tenant resolution, the
    `:binary` column and the vault's bytes stored verbatim are the same for
    all three.
  - **Tenant resolution.** `Encryptor.Ecto.Tenant` holds the current tenant
    for a unit of work, `Encryptor.Ecto.TenantContext` is the behaviour a
    host implements to resolve it some other way, and
    `Encryptor.Ecto.TenantScope` scopes an ExUnit case or one `describe`
    block to a tenant (ADR-0001 decision 5c).
  - **Blind indexes.** `Encryptor.Ecto.BlindIndex` declares a keyed,
    equality-only fingerprint column beside an encrypted one, so equality on
    plaintext becomes equality on fingerprint (ADR-0003).
  - **The migrator.** `Encryptor.Ecto.Migration` compiles a plan and
    `Encryptor.Ecto.Migrator` rewrites the columns it names against live
    traffic, with `verify/2` as the read-only half; the `mix` tasks are thin
    parsers over the library functions so a release can run one (ADR-0002,
    ADR-0004).
  - **The key provider.** `Encryptor.Ecto.KeyStore` is the store-backed
    `Encryptor.Provider`: a wrapped-key table owned here, key descriptors
    out, because the vault defines no storage of its own.

  The error vocabulary is `Encryptor.Ecto.Error` and the exceptions that
  `use` it. Its redaction rule is enforced structurally rather than by
  convention: nothing this package raises, logs or inspects carries
  plaintext, ciphertext bytes or key material (ADR-0001 decision 6).
  """
end
