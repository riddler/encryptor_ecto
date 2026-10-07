# Documentation

The pages here are organized by what a reader needs from them, in the
[Diataxis](https://diataxis.fr) sense: a page either helps you *do* something or
helps you *understand* something, and mixing the two makes it worse at both. A
page that starts explaining in the middle of a runbook, or starts instructing in
the middle of an explanation, is a defect here rather than a stylistic
preference.

## Explanation

Read at leisure, away from a terminal.

- [What changes when you move off cloak_ecto](explanation/moving-off-cloak.md) -
  what a migration onto this package changes *semantically*: per-scope keys
  where cloak had one key, the encryption context and the substitution it
  forbids, fail-closed scope and the boundary audit that is the real cost
  of adoption, crypto-shredding and the field that opts out, why encrypted
  columns are not queryable, what a keyed blind index restores and what it does
  not, and why the mixed window is a downgrade until `legacy:` is dropped.
- [Why the Ecto types are a second package](explanation/why-a-second-package.md) -
  where the line between the vault and this package falls and the test that
  draws it, the alternatives to two packages (one package, an optional
  dependency, no Ecto layer), and what the split costs: the exact pin and the
  public contract between the two.
- [The threat model of the Ecto layer](explanation/threat-model.md) - what
  this package adds above the vault and what it gives an attacker: what a
  database dump reveals beside the ciphertext, what one scope's index key
  adds, what a dump kept after a shred still shows, the key store's columns,
  the migrator's plaintext window, and what was tested and how. Everything
  below the Ecto type is the vault's threat model, which it links.

## How-to guides

Task-shaped, for someone who already understands the target state.

- [How to migrate a host app off cloak_ecto](guides/migrate-from-cloak.md) - the
  migration runbook of ADR-0004 decision 8, step by step: the command for each
  step in release `eval` and `mix` form, what its output should say, what to do
  when it differs, and where reversibility actually ends.
- [How to bind extra identifiers into an encrypted field's context](guides/bind-extra-context.md) -
  the `:context` option: what belongs in a declared context and what does not,
  how the pairs compose with the vault's static ones, which refusals a
  declaration buys, why a bound value is permanent, and what changing one
  costs.
- [How to keep scope keys in Google Cloud KMS through the key store](guides/gcp-kms-key-store.md) -
  one `CryptoKey` per scope: the Goth token server, the key store's
  `:gcp_kms` option, provisioning a `"gcp_kms_ciphertext"` row, and the
  shred - destroying the key version, deleting the row, the restore window,
  and the answers the application sees at each step, including the one
  ADR-0005 Amendment A5 proposes.
- [How to keep a customer scope and an agreement scope in two vaults](guides/two-vaults-customer-and-agreement.md) -
  a customer vault for platform data and credentials beside an agreement
  vault for data shared under a data agreement: why two vaults rather than
  a composite selector, the two key tables, the process resolver and a
  resolver fed from the row, the shred of one agreement, and what each
  vault's shred reaches.
- [How to resolve the scope in jobs and projectors](guides/scope-in-jobs-and-projectors.md) -
  why the scope stops at the process that set it, capturing it in the caller
  and re-establishing it with `wrap/2` in a `Task` and in a background job's
  `perform/1` (the Oban worker as one line of delegation), and a projector
  that hands each event's scope to a resolver of its own, so that replay
  and inline projection neither need nor disturb the process scope.

## Reference

No page here. The mix tasks' flag tables, exit codes and grammar are their own
`@moduledoc`s, rendered by ExDoc, so that they live with the code that parses
them and the two cannot drift (ADR-0004 decision 10). Read them with
`mix help encryptor.ecto.migrate`, `mix help encryptor.ecto.verify`,
`mix help encryptor.ecto.gen.plan` and `mix help encryptor.ecto.gen.migration`;
the grammar they implement is ADR-0004 decision 6.

## Tutorial

**There is deliberately no tutorial, and this is the note saying so** - so that
nobody writes one on the reasonable observation that the set has a hole in it.

A tutorial's promise is a safe place to practice. For a destructive migration
performed on live production data, a practice article would either operate on a
host's real data, which is the thing it is supposed to teach them to be careful
with, or on a toy that omits every property making the real one hard: live
traffic, per-row scopes, rows that will not decrypt. The dry run is the rehearsal.
It runs against the host's own data, it is a step of the how-to guide, and a
fake one alongside it would compete with it (ADR-0004 decision 10).

## Records

- [Architecture decision records](adr/README.md) - the contracts every page
  above renders.
- `plans/` - implementation plans derived from those records. Working documents,
  not user documentation.
