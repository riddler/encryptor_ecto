# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for unreleased work are not written here directly. Each issue drops a
fragment in [`changelog.d/`](changelog.d/README.md); the fragments are assembled
into a version section at release. See that README for the format and for when a
change warrants an entry at all.

## [0.2.0] - 2026-08-28

### Added

- `Encryptor.Ecto.Binary` declares an encrypted `:binary` field: `use` it with
  a vault, name the module from a schema, and every read and write goes
  through the vault without a call site changing.
- The table and column a field was declared with are bound into every message
  as encryption context, so bytes lifted out of one column fail authentication
  in another rather than decrypting into the wrong place.
- A dump or load with no tenant resolved raises `MissingTenantError` naming
  the table and column, instead of falling back to a default tenant and
  writing a row nobody can recover.
- `Encryptor.Ecto.String` declares an encrypted text field: everything
  `Encryptor.Ecto.Binary` does, with a cast arm that accepts only valid UTF-8,
  so bytes from a mis-decoded payload become an error on the field instead of a
  column that decrypts years later into something no reader can render.
- `Encryptor.Ecto.Map` declares an encrypted map field, serialized through
  `:json` - any module exporting `encode!/1` and `decode!/1`, `Jason` by
  default - and checked at the declaration rather than on the first write.
- A loaded map has string keys - guaranteed by the default serializer, and
  trusted of a host-supplied one - and `%{}` round-trips as `%{}` rather than
  collapsing into `nil`.
- A struct handed to a map field is refused at `cast/2` rather than silently
  round-tripping into a plain map.
- A serializer failure raises `Encryptor.Ecto.SerializationError` naming the
  serializer and the direction, with the serializer's own exception reduced to
  its module: `Jason`'s carries the value it could not encode, and this package
  does not pass that on.
- A field declared `tenant: :none` must name a `:single`-profile vault, and
  pairing one with a `:tenant`-profile vault now raises
  `Encryptor.Ecto.VaultProfileError` naming the field, the vault and the
  profile - instead of surfacing on the first write as whatever the vault's
  key provider happens to refuse first, which names neither.
- `Encryptor.Ecto.Binary`'s documentation states at the option itself what
  `tenant: :none` costs: those ciphertexts are not crypto-shreddable with a
  tenant key.
- `Encryptor.Ecto.Declarations.check_unique!/1` refuses a deploy in which two
  encrypted fields share one declared table and column - fields that can
  silently decrypt each other's bytes - and `list/1` reports what a deploy
  considers encrypted and under what context.
- The `:table` and `:column` pins may be written at the field as well as at
  the `use`, so renaming a physical table or column is a one-line change that
  leaves every stored row readable.
- Encrypted-field failures raise a named exception - `MissingTenantError`,
  `MissingContextError`, `EncryptError`, `DecryptError` or
  `SerializationError` - each carrying the declared table, the declared column,
  the encryption-context key names and the upstream reason, and none of them
  carrying a plaintext, a ciphertext or key material in its message or its
  `Inspect` form.
- `Encryptor.Ecto.Tenant` holds the current tenant for a unit of work, with
  `wrap/2` restoring the previous scope so a pooled process cannot leak one.
- `Encryptor.Ecto.TenantContext` is the one-callback behaviour a host
  implements to resolve the tenant its own way; the default `:scope` strategy
  is an ordinary implementation of it.
- `Encryptor.Ecto.TenantScope.scope_tenant/1` scopes an ExUnit case or a single
  `describe` block to a named tenant, so a host's suite meets fail-closed
  tenancy without either a default tenant or six lines of setup per case.
- `Encryptor.Ecto.Tenant` documents the full list of boundaries a host is
  expected to wrap, rather than naming a few of them in passing.
- `Encryptor.Ecto.BlindIndex.blind_index/3` declares a keyed blind index on an
  encrypted field, inside the schema beside the column it indexes. The
  declaration is the one place an index's normalization and key derivation
  live, so the helper that writes the column and the helper that queries it
  cannot disagree about either.
- `Encryptor.Ecto.BlindIndex.Normalizer` ships the founding set - `:none`,
  `:trim`, `:downcase`, `:email`, `:digits`, and a host `{module, function}`.
  The built-ins are total on every binary, including one that is not valid
  UTF-8; a host normalizer that raises, throws, exits, is not exported, or
  returns a non-binary produces `NormalizationError` naming the table, the
  column and the index, and no value.
- `Encryptor.Ecto.BlindIndex.Declaration` is the read surface a helper
  resolves an index through: `list/1`, `fetch!/3`, `derivation!/1` and
  `normalize!/2`.
- Declaring a blind index on a `tenant: :none` field with no `:scope`, or with
  `scope: :tenant`, is a compile error. `scope: :global` is the only
  possibility there and it still has to be written, because the reviewer
  reading that schema line is the person who needs to know the column is
  cross-tenant correlatable and survives a tenant shred.
- Declaring one on a field this package does not encrypt is a compile error,
  as are an index column that is not a field on the schema, an index column
  that is itself encrypted, and two declarations sharing an index name or a
  `{source, column}` pair.
- `Encryptor.Ecto.BlindIndex.Derivation` derives a blind index's key through
  the vault's `derive/3`: the index tree is a salted subkey under the vault's
  reserved `"encryptor/v1/blind-index"` label, and the table, column, index
  name and version are the info string inside it, so an index key can never be
  an encryption key and two columns holding the same plaintext produce
  unrelated index values.
- Index keys are salted with the vault's per-deployment `:derivation_salt`,
  so two deployments provisioned from the same key material - a restored
  backup, a cloned staging environment - derive unrelated index values, and a
  vault without one refuses to derive rather than deriving under nothing.
- Key material never reaches this package: there is no argument on any
  function in the derivation that a tenant master key could be passed as, and
  every byte comes back from the vault already derived.
- A blind index resolves its tenant through the encrypted field's own
  configured strategy, so a host that replaced the default with a resolver
  module gets the same replacement for its indexes, and a missing tenant
  raises `MissingTenantError` rather than silently matching nothing.
- `Encryptor.Ecto.BlindIndex.DerivationError` reports a derivation that could
  not proceed, naming the table, column, index name and version, and never a
  value.
- `Encryptor.Ecto.BlindIndex.put_index/3` computes a declared index column
  from the cast plaintext: it applies the field's normalizer, derives the
  index key through the vault, and puts the HMAC. A source field that was not
  changed is not recomputed, and a source set to `nil` sets the index to `nil`
  - a `NULL` plaintext beside a non-`NULL` index would leak that a value
  exists (ADR-0003 decision 8).
- `Encryptor.Ecto.BlindIndex.where_eq/3` adds an equality constraint on the
  index column, against a computed value. Equality is the whole surface
  permanently (ADR-0003 decision 9): there is no `where_like`, no `where_gt`,
  no ordering helper, and no operator argument that could be made to generate
  one.
- `Encryptor.Ecto.BlindIndex.where_eq_candidates/3` is the same constraint
  under the weaker contract a truncated index answers under. `where_eq/3`
  refuses a truncated index by name, so a call site that has to filter the
  rows after decrypting them cannot forget that it does.
- `Encryptor.Ecto.BlindIndex.compute/3` returns the index value itself, for a
  host building its own query. It is a directly usable search token, and is on
  the never-logged list beside plaintext and key material.
- Each of the three read helpers has a four-argument form naming the index
  column, for a field carrying more than one index - ADR-0003 decision 7's
  rotation window, where both versions are declared and the source field names
  neither, and decision 3d's per-tenant and `scope: :global` pair. The
  three-argument form refuses an ambiguous field rather than choosing a key
  for the caller.
- `use Encryptor.Ecto.Migration, repo: MyApp.Repo` declares a migration plan:
  `rewrite` per schema, `tenant_from/1` or `tenant/1` for how the tenant is
  resolved, and `field/2` naming the `from:` and `to:` type modules of each
  column. The module compiles to an `Encryptor.Ecto.Migrator.Plan` struct,
  handed over by a generated `__plan__/0`.
- A plan that would fail on row one fails at `mix compile`: every field and
  `into:` column is checked against the schema, `tenant_from` against its
  columns, every `from:` module against the shapes
  `Encryptor.Ecto.Migrator.Source` can read, and every `to:` module against
  the load *and* dump pair it has to answer. Each refusal is a `CompileError`
  naming the schema and field, at the line the plan declared it.
- `Encryptor.Ecto.Migrator.Source` is the behaviour a migration plan's `from:`
  names: one `load/2` callback that reads a column's pre-migration value and
  returns `{:ok, plaintext}` or `{:error, reason}` rather than raising.
- `Encryptor.Ecto.Migrator.Source.EctoType` adapts any module that can already
  read those bytes - a plain `Ecto.Type` with `load/1`, which is every
  `cloak_ecto` type module and every hand-rolled one, or an
  `Ecto.ParameterizedType` with `load/3` - so migrating off a prior encryption
  scheme needs no dependency on the library being left behind.
- A failed legacy read is data rather than an exception: an `:error` return and
  a raise from the adapted module both become `{:error, reason}`, scoped to the
  one row, so the migrator can classify the row instead of losing the pass.
- A zero-arity function returned by a source is invoked once and its result is
  the plaintext, so a legacy type that defers its decrypt migrates the value
  rather than the closure.
- `Encryptor.Ecto.Migrator.Source.Plaintext` reads a column that was never
  encrypted, for the backfill leg of adopting encryption on one.
- A `from:` module that can read nothing fails at `mix compile` with an error
  naming the field, rather than on the first row of a live pass.
- `Encryptor.Ecto.Migrator.run/2` rewrites the ciphertext columns a plan names,
  against live traffic: every row is probed before it is rewritten, so running
  the pass twice, resuming it from the wrong cursor or interrupting it midway
  all converge on the same end state.
- Writes are compare-and-swap against the exact bytes the migrator read, so a
  row the application wrote in the meantime is counted as concurrently
  migrated rather than clobbered with a re-encryption of stale plaintext.
- Rows are visited in primary-key order with keyset pagination, one batch per
  transaction, with the batch's cursor and counts recorded in the same
  transaction. Single-column integer and binary primary keys are supported;
  a composite or otherwise unordered key is refused with a message naming the
  schema rather than paged over under a guess.
- The checkpoint key carries the schema prefix, so a host looping `run/2` over
  its prefixes gets one cursor per prefix instead of the second prefix
  resuming at the first's and skipping every row below it.
- `mode:` is required and has no default: `:dry_run` rehearses every read,
  probe, decrypt and encrypt and discards the write, `:write` performs it.
- A missing checkpoint table is refused with a message naming the generator -
  this package issues no DDL - and `checkpoint: :none` runs the documented
  degraded mode with no checkpoint at all.
- Failures are loud and the default is to stop: an unreadable row halts the
  pass, rolls back its batch, and reports the primary key, the schema, the
  field and a reason that carries no plaintext, ciphertext or key material.
  `on_error: :continue` records it and finishes, and still exits non-zero.
- `Encryptor.Ecto.Migrator.verify/2` is the read-only half of a migration: the
  same plan, the same classification, no writes, and a non-zero arm for any
  row that is not already in the target state. It is the acceptance test at
  the end of a rotation, the drift check a host runs on a schedule, and the
  signal that the mixed window has closed and `legacy:` can be dropped.
- `sample:` verifies a random draw of rows per field rather than the whole
  scope, for the scheduled check. The draw is random rather than the first
  rows in key order, because key order is the order a pass writes in and a
  prefix of it is the region a partial pass has already migrated.
- `Encryptor.Ecto.Migrator.Report.verified?/1` is that stricter arm as a
  function: every row `:already_target` or `:null`, and no failures. It counts
  a class it has never heard of against a verification, so a class added later
  cannot arrive as a green report.
- `Encryptor.Ecto.Migrator.Census` renders the SQL an operator or a DBA runs
  with no application and no key material: a format census over a byte prefix
  wide enough to separate two formats whose first byte collides, rotation
  progress for one tenant, and a before/after count showing nothing became
  `NULL` or empty.
- `legacy:` opens the migration window: name the type module the column was
  read with before, and a row the migration has not reached yet still loads,
  through that module, while every write goes out in the new format. The
  primary load is always attempted first, and the fallback hangs off the
  vault's refusal of the stored bytes alone - a missing tenant or a missing
  required context key raises, because answering a host misconfiguration with
  a successful legacy read turns a configuration bug into a silent year of
  un-migrated rows.
- A load that falls through emits `[:encryptor_ecto, :legacy_load]`, counting
  one, with the table and the column and nothing else. The window is
  per-field, so the pair is what tells a host which of its twelve encrypted
  columns still has a legacy reader open. The counter is a convenience and not
  a proof: it is evidence about traffic rather than about rows, and
  `Encryptor.Ecto.Migrator.verify/2` stays the signal a host drops `legacy:`
  on.
- When both loads fail, the exception raised is the primary
  `Encryptor.Ecto.DecryptError`. The legacy attempt's reason travels in the
  non-contractual `:engine` field, reduced to tags and module names, so a
  legacy reader that prints the bytes it choked on cannot put them into the
  failure a host sees.
- A migration plan field may declare `source_authenticated: false`, which
  acknowledges that its legacy cipher has no authentication tag: a wrong key
  or a corrupt row decrypts to something rather than failing, so a successful
  load is not evidence. Its rows are then counted `:migratable_unverified`
  rather than `:migratable`, in a dry run, a write and a verification alike,
  so no report claims a verification that never happened.
- `validate:` takes a host-supplied `(term() -> boolean())` applied to the
  loaded plaintext before it is re-encrypted - a card number is sixteen
  digits, a serialized map parses, a kept legacy hash column recomputes. A row
  it rejects is `:undecryptable` and is not written. There is no built-in
  generic validator: a printable?/UTF-8? check would be reassurance rather
  than a control, and only the host knows what its own values look like.
- `Encryptor.Ecto.Migrator.Report.classes/0` gains `:migratable_unverified`,
  which counts against `verified?/1` like every class but `:null` and
  `:already_target`.
- `mix encryptor.ecto.migrate PLAN --mode dry-run|write` runs a migration plan
  through `Encryptor.Ecto.Migrator.run/2`. `--mode` is required and has no
  default; `--batch-size`, `--resume`/`--no-resume`, `--prefix`,
  `--no-checkpoint`, `--only Schema:field`, `--only-tenant`,
  `--except-tenant` and `--on-error halt|continue` each map onto one option of
  `run/2` and add no capability the library function lacks.
- `mix encryptor.ecto.verify PLAN [--sample N|all] [--prefix PREFIX]` runs the
  read-only pass. Those two flags and no others: a migrate flag passed here
  refuses and names the verb it belongs to, rather than being silently
  ignored by a `verify/2` that has no such option.
- `mix encryptor.ecto.gen.migration` writes the checkpoint table's migration
  into the host's tree - `--table` renames it, `--migrations-path` places it.
  It issues no DDL and never overwrites an existing migration for the table;
  the host reviews the file, commits it, and runs it with its own
  `mix ecto.migrate`.
- The tasks carry the flag tables and the exit codes in their `@moduledoc`s,
  which are the reference half of the documentation set. Exit codes: `0` the
  pass completed with no failures, `1` the pass ran and found something (a dry
  run that finds `:undecryptable` rows included), `2` a usage error, a plan
  that will not compile, or a run that could not start.
- `mix encryptor.ecto.gen.plan` writes a migration plan skeleton into the
  host's tree. It loads the host's application, reads every Ecto schema in it,
  and emits one `rewrite` block per schema with one `field` line per field
  whose type is a module rather than a built-in Ecto type. `--repo` is read
  from the app's `:ecto_repos` when that names exactly one; `--app`,
  `--module` and `--output` cover the rest, and the generator never overwrites
  a plan that already exists.
- The generated file **does not compile**, on purpose (ADR-0004 decision 7),
  and carries a comment explaining why so that whoever runs `mix compile` next
  does not read it as a bug. Three facts are left visibly unanswered because a
  generator cannot know them: every block emits `tenant_from
  :TODO_tenant_column`, which the plan DSL rejects at compile time - guessing
  the tenant column re-encrypts every row under one tenant's key, and a
  skeleton that compiled would be a skeleton somebody ran; every field's `to:`
  is a comment rather than a value, since a half-guessed target type produces
  a diff that looks reviewed; and the field list over-reports, because per
  ADR-0004 decision 1 the generator tests for no other library's marker
  function, so a custom type that encrypts nothing is listed too. A false
  positive a human deletes beats a field nobody noticed.
- This is the one member of the task family with no release equivalent
  (ADR-0004 Q6): reading `__schema__(:type, field)` needs the host's schema
  modules loaded, which a Mix task has and a release command does not. It
  writes source into a working tree, which is not a thing a release does.

### Changed

- **`:bits` is applied.** A blind index declared `bits: 64`, `128` or `192`
  now stores that many bits - the leading 8, 16 or 24 bytes of the
  `HMAC-SHA256` - instead of the full 32 bytes it stored while ADR-0003
  decision 6's option half was carried unapplied. `bits: 256` remains the
  default and is unchanged. This is a behaviour change for any declaration
  already carrying a narrower width; no host has stored a blind index value
  yet, so nothing needs reindexing.
- `Encryptor.Ecto.BlindIndex.Value.byte_width/1` reports a declaration's
  stored width in bytes, which is what a host sizes its index column against.
- ADR-0004 gains a dated proposed amendment answering Q2 on the operator's
  ruling: silence about `source_authenticated:` is allowed only where
  authentication is provable from the `from:` type, and every other `from:`
  must declare it explicitly. Decision 3d's worked example changes with it.
  The compile-time enforcement is a later bead's; only the record's text lands
  here.
- `mode: :write` is refused, before a row is read, for a field that declares
  `source_authenticated: false` without a `validate:`. `mode: :dry_run` and
  `verify/2` still run it, which is how such a field is inspected first.
- A plan field whose `from:` type is not one of this package's own
  vault-backed types must now declare `source_authenticated:` explicitly, and
  fails at `mix compile` naming the schema and field if it does not. Silence
  is allowed only where authentication is provable - the context-change case,
  where `from:` names a type this package wrote the bytes with. Everywhere
  else `from:` is the host's own legacy reader, and this package cannot tell
  an AEAD cipher from a stream cipher by looking, so it asks where the
  question is cheap. Upgrading hosts declare `source_authenticated: true` per
  legacy field: the reviewable assertion that someone checked.

### Fixed

- `Encryptor.Ecto.String` and `Encryptor.Ecto.Map` fields now carry the marker
  that identifies an encrypted field, so `Encryptor.Ecto.Declarations` sees
  them. Its uniqueness check previously covered only `Encryptor.Ecto.Binary`
  fields, which meant a text or map field sharing a declared `{table, column}`
  pair with another field passed a check whose whole purpose is to deny that
  pairing - the two are mutually substitutable, since both ride the declared
  pair as AAD through the same code.

### Notes

- **Both sides raise on a missing tenant, `where_eq/3` included.** A query
  *built* outside tenant scope raises where it is built rather than executing
  and matching nothing, which is the failure ADR-0003 decision 5 calls the
  worst this feature can have, because it looks exactly like "the record does
  not exist".
- A write-side computation asks the field's tenant strategy with `:dump` and a
  read-side computation asks with `:load`, matching what the encrypted field
  itself would be doing at the same moment.
- `:bits` and `:slow` are carried rather than applied *by these helpers*:
  `where_eq/3`'s refusal reads the declared width and no helper computes with
  it. `:bits` is applied one layer down, in
  `Encryptor.Ecto.BlindIndex.Value` - see this release's `ece-6a6` entry, which
  landed after this one and supersedes its original claim that a declaration
  written with `bits: 64` stores a full-width value. `:slow` remains carried
  and unapplied.
- A tenant *key* rotation is not ADR-0003 decision 7's rotation. Only the
  current encryption key is consulted upstream, so rotating a tenant's key
  changes every index key under it without any declaration changing, and
  values stored under the superseded key stop being derivable - `where_eq/3`
  then matches nothing and raises nothing. The record does not describe that
  case and this package invents no behaviour for it: a host rotating a tenant
  key must reindex that tenant's index columns.
- **The output is truncated, never the key.** The index key stays the full 32
  bytes the derivation produces, and `:bits` never reaches the HKDF `info`
  string - so a width change stores different bytes under the *same* key. A
  shortened HMAC key would be a weakened HMAC; decision 6 asks for a collision
  knob on the stored value, and collisions are a property of the value's
  width.
- **The leading bytes are kept.** RFC 2104 section 5 defines HMAC truncation
  as "the leftmost t bits" and NIST SP 800-107 section 5.3.1 says the same for
  any approved hash output. Either end is equally sound here, so this is a
  convention rather than a security choice - but it is a constant a host's
  stored bytes depend on forever, so it is written down at
  `Encryptor.Ecto.BlindIndex.Value` rather than left to the reader of a
  `binary_part/3`.
- **Truncation happens in one place**, inside the single function every
  surface computes through, so `put_index/3` and `where_eq_candidates/3`
  cannot store and pin different widths. That is ADR-0003 decision 5's promise
  applied to decision 6, and it is why `:bits` is read at no call site.
- A `:bits` change invalidates the column exactly as a normalizer change does
  (decision 7): the stored value changes even though the key does not, so the
  two-column dance is the migration.
- **`:slow` is still carried rather than applied.** ADR-0003 decision 6 puts
  Argon2id's parameters in "the vault's configuration rather than this
  package's", and the vault exposes no Argon2id surface to read them from.
  Choosing a parameter set here would be this package making a cryptographic
  decision inline, which this repository's conventions call a defect even when
  the choice is a good one. A declaration written with `slow: true` is
  accepted, checked and carried, and does nothing.
