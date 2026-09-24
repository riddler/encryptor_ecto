# ADR-0006: Scope names the key's owner here too, and the key store's column keeps its name

Status: accepted (2026-09-24)

## Context

`encryptor`'s enc-ADR-0009 renames the thing a per-owner key belongs to from
*tenant* to *scope*: the context profile `:tenant` becomes `:scoped`, the
Elixir names that said `tenant_ref` say `scope_ref`, and every string the
vault writes into a ciphertext or a wrapped key keeps its v1 spelling
(enc-ADR-0009 decisions 2 to 4). The vault side of that rename is on
`encryptor`'s main at `9ad74e2`, whose changelog fragment for it records the
change as breaking "with no deprecated aliases" (`changelog.d/enc-8cl.md` at
`9ad74e2`).

This package uses the same noun on its own surface, and more of it: the
process store a host sets at the edge of a unit of work, the behaviour a
resolver implements, the type option that picks a strategy, the blind
index's key-derivation option, the migration plan's DSL, the migrator's
filters and its command-line flags, the exception family's fields and error
terms. Two of those collide with the new word as soon as it arrives. The
blind index already spells an option `scope:` (`:tenant | :global`,
`Encryptor.Ecto.BlindIndex.Declaration`, `@options` at `ad08848`), and the
type option's default value is already `:scope` (`tenant: :scope`,
`Encryptor.Ecto.Binary.validated_tenant/1`). A test-support module is named
`Encryptor.Ecto.TenantScope` and exports a macro named `scope_tenant/1`
(`lib/encryptor/ecto/tenant_scope.ex` at `ad08848`). A rename that only
swapped the noun would produce `scope: :scope`, a blind index `scope:` that
means something different from a type `scope:`, and a `Scope` module beside
a `ScopeScope` one.

Some of the same noun is not this package's to rename. The key store's
table has a `tenant_ref` column with a unique index over it, created in every
adopter's database by the migration `mix encryptor.ecto.gen.key_store_migration`
generates (`Mix.Tasks.Encryptor.Ecto.Gen.KeyStoreMigration.source/2` at
`ad08848`). Every ciphertext this package stores carries the vault's
`"tenant_ref"` context key, which enc-ADR-0009 decision 4 pins.

All `lib/` cites in this record were read at `ad08848` unless another SHA is
named.

## Decision

**1. This package takes the Scope name for every Elixir surface that
carries the owner noun,** following enc-ADR-0009 decision 1: a scope is the
opaque, non-empty string selector a host keys by, with no parent and no
children. The rename is later, scheduled work; this record decides its
names, and nothing in `lib/` changes with it.

**2. The rename table.** Public names, and the names a host can see through
a public value (a struct field, a map key, an error term, a flag). Private
helpers and local variables follow the table without being listed.

| # | Today (at `ad08848`) | After the rename | Where it is defined |
|---|---|---|---|
| 1 | module `Encryptor.Ecto.Tenant` | `Encryptor.Ecto.Scope`; `put/1`, `get/0`, `fetch!/0`, `clear/0` and `wrap/2` keep their names and behaviour | `lib/encryptor/ecto/tenant.ex` |
| 2 | behaviour `Encryptor.Ecto.TenantContext` | `Encryptor.Ecto.ScopeContext`; the callback `resolve/2` and the types `operation/0` and `params/0` keep their names | `lib/encryptor/ecto/tenant_context.ex` |
| 3 | module `Encryptor.Ecto.TenantContext.Scope` (the default strategy) | `Encryptor.Ecto.ScopeContext.Process` | `lib/encryptor/ecto/tenant_context/scope.ex` |
| 4 | module `Encryptor.Ecto.TenantScope` (test support) | `Encryptor.Ecto.ScopeSetup` (decision 4) | `lib/encryptor/ecto/tenant_scope.ex` |
| 5 | exception `Encryptor.Ecto.MissingTenantError` | `Encryptor.Ecto.MissingScopeError` | `lib/encryptor/ecto/missing_tenant_error.ex` |
| 6 | module `Encryptor.Ecto.Migrator.RowTenant` | `Encryptor.Ecto.Migrator.RowScope` | `lib/encryptor/ecto/migrator/row_tenant.ex` |
| 7 | macro `TenantScope.scope_tenant/1` | `ScopeSetup.setup_scope/1` | `Encryptor.Ecto.TenantScope.scope_tenant/1` |
| 8 | function `TenantScope.put_tenant/1` | `ScopeSetup.put_scope/1` | `Encryptor.Ecto.TenantScope.put_tenant/1` |
| 9 | function `RowTenant.with_tenant/2` | `RowScope.with_scope/2` | `Encryptor.Ecto.Migrator.RowTenant.with_tenant/2` |
| 10 | plan DSL macro `tenant_from/1` | `scope_from/1` | `Encryptor.Ecto.Migration.tenant_from/1` |
| 11 | plan DSL macro `tenant/1` | `scope/1` | `Encryptor.Ecto.Migration.tenant/1` |
| 12 | `Encryptor.Ecto.Migration.__tenant__/3` (`@doc false`, the target of rows 10 and 11) | `__scope__/3` | `Encryptor.Ecto.Migration.__tenant__/3` |
| 13 | `Encryptor.Ecto.Migrator.Keyset.tenant_filter/4`, and the `tenant_column` parameter of `batch_query/7` and `sample_query/6` | `scope_filter/4`; the parameter is `scope_column` | `Encryptor.Ecto.Migrator.Keyset.tenant_filter/4` |
| 14 | `.formatter.exs` exported `locals_without_parens` entries `scope_tenant: 1`, `tenant: 1`, `tenant_from: 1` | `setup_scope: 1`, `scope: 1`, `scope_from: 1` | `.formatter.exs`, `locals_without_parens` |
| 15 | type option `:tenant` on `use Encryptor.Ecto.Binary` and every type built on it, `Encryptor.Ecto.Map` included | `:scope` | `Encryptor.Ecto.Binary`, `@known_options`; `Encryptor.Ecto.Map`, `@type opts` |
| 16 | that option's default value `:scope` | `:process`; `:none` and a resolver module are unchanged | `Encryptor.Ecto.Binary.validated_tenant/1` |
| 17 | blind index option `:scope` | `:derive` | `Encryptor.Ecto.BlindIndex.Declaration`, `@options` |
| 18 | that option's value `:tenant` (the default) | `:per_scope` (still the default); `:global` is unchanged | `Encryptor.Ecto.BlindIndex.Declaration`, `@scopes` |
| 19 | migrator options `:only_tenants` and `:except_tenants` | `:only_scopes` and `:except_scopes` | `Encryptor.Ecto.Migrator`, `@known_options` |
| 20 | command-line flags `--only-tenant` and `--except-tenant` | `--only-scope` and `--except-scope` | `Encryptor.Ecto.Migrator.CLI`, `@migrate_switches` and `@migrate_only_flags` |
| 21 | exception-family struct field `:tenant`, and the `"tenant"` label in every message | field `:scope`, label `"scope"` | `Encryptor.Ecto.Error`, `@type common` and `common_detail/1` |
| 22 | params key `:tenant`, frozen by `init/2` into every encrypted field's params | `:scope` | `Encryptor.Ecto.Binary`, `@type params`; read by `Encryptor.Ecto.BlindIndex.Derivation`'s `@type field_params` and by the `@our_params` lists of `Encryptor.Ecto.Migrator` and `Encryptor.Ecto.Migrator.Source` |
| 23 | `%Encryptor.Ecto.BlindIndex.Declaration{}` fields `:scope` and `:scope_declared?` | `:derive` and `:derive_declared?` | `Encryptor.Ecto.BlindIndex.Declaration`, `defstruct` |
| 24 | `%Encryptor.Ecto.BlindIndex.Derivation{}` field `:scope`, its `new!/1` option `:scope`, and `@type scope :: :tenant \| :global` | field and option `:derive`; `@type derive :: :per_scope \| :global` | `Encryptor.Ecto.BlindIndex.Derivation`, `defstruct` and `@type scope` |
| 25 | `Derivation.selector/0` member `{:tenant, String.t()}` | `{:scope, String.t()}`; `:global` is unchanged | `Encryptor.Ecto.BlindIndex.Derivation`, `@type selector` |
| 26 | `@type Encryptor.Ecto.Migrator.Plan.tenant/0`, and the rewrite map's `:tenant` key | `Plan.scope/0`, key `:scope` | `Encryptor.Ecto.Migrator.Plan`, `@type tenant` |
| 27 | `%Encryptor.Ecto.Migrator.Pass{}` fields `:tenant`, `:tenant_column`, `:only_tenants`, `:except_tenants` | `:scope`, `:scope_column`, `:only_scopes`, `:except_scopes` | `Encryptor.Ecto.Migrator.Pass`, `@type t` |
| 28 | `Pass.target_header/0` key `:tenant_ref?` | `:scope_ref?` | `Encryptor.Ecto.Migrator.Pass`, `@type target_header` |
| 29 | the `:tenant` key of the params an arity-3 `from:` module receives from the migrator | `:scope` | `Encryptor.Ecto.Migrator.Pass`, `source_params/2` |
| 30 | `Encryptor.Ecto.KeyStore.row/0` key `:tenant_ref` | `:scope_ref`, the name enc-ADR-0009 gives the same value; the column it is selected from keeps its name (decision 3) | `Encryptor.Ecto.KeyStore`, `@type row` |
| 31 | the census `:progress` query's `:tenant` placeholder, and its description "rotation progress for one tenant" | placeholder `:scope`; "rotation progress for one scope" | `Encryptor.Ecto.Migrator.Census`, `progress/2` |
| 32 | error reason `:no_tenant_in_scope` | `:no_scope_in_process` | `Encryptor.Ecto.TenantContext.Scope.resolve/2` |
| 33 | error reason `{:tenant_profile_vault, vault}` | `{:scoped_profile_vault, vault}` | `Encryptor.Ecto.Binary`, `assert_single_profile_vault!/1` |
| 34 | error reason `:field_declared_tenant_none` | `:field_declared_scope_none` | `Encryptor.Ecto.BlindIndex.Derivation.selector!/3` |
| 35 | error reason `{:invalid, :scope, :not_tenant_or_global}` | `{:invalid, :derive, :not_per_scope_or_global}` | `Encryptor.Ecto.BlindIndex.Derivation`, `validate_scope!/1` |
| 36 | error reasons `{:no_row_tenant, op}`, `{:null_tenant_column, op}`, `{:unusable_tenant_column, op}` | `{:no_row_scope, op}`, `{:null_scope_column, op}`, `{:unusable_scope_column, op}` | `Encryptor.Ecto.Migrator.RowTenant.resolve/2` |
| 37 | process-dictionary keys `:"$encryptor_ecto_tenant"` and `:encryptor_ecto_migrator_row_tenant` | `:"$encryptor_ecto_scope"` and `:encryptor_ecto_migrator_row_scope` | `Encryptor.Ecto.Tenant`, `@dict_key`; `Encryptor.Ecto.Migrator.RowTenant`, `@key` |
| 38 | message text that names the owner noun | says *scope*, and spells the renamed option, macro, flag or module | the headlines of row 5's exception and of `Encryptor.Ecto.VaultProfileError`; `Encryptor.Ecto.Tenant.fetch!/0`; `put_tenant/1`; `Encryptor.Ecto.Binary.validated_tenant/1`; `Encryptor.Ecto.BlindIndex`, `validate_scope!/2`; the `Encryptor.Ecto.Migration` messages (`missing_tenant_message/1`, `duplicate_tenant_message/1`, `scope_tenant_message/1`, `not_a_resolver_message/2`); the `Encryptor.Ecto.Migrator` messages (`tenants!/3`, `assert_tenant_list!/2`, `unfilterable_message/2`, `rotation_tenants_message/1`, `untenanted_rotation_message/1`); the skeleton `mix encryptor.ecto.gen.plan` writes, which emits `scope_from :TODO_scope_column` |

The telemetry this package emits carries no owner noun and is not renamed:
`[:encryptor_ecto, :legacy_load]`'s metadata is closed at `:table` and
`:column` (`Encryptor.Ecto.Binary`, `emit_legacy_load/1`).

Prose follows the table: every moduledoc, the README, `docs/guides/`,
`docs/explanation/`, and the comments in `.quality.exs` and
`coveralls.json` that name `Encryptor.Ecto.TenantContext`. Doc examples
follow too, including the key store's `key_ring: "encryptor-tenant-keys"`
and `MyApp.TenantVault`: those are example values in a host's own
configuration, a host that copied one keeps what it configured, and this
package never reads either. Accepted records are not edited; this record is
the map from their spellings to the new ones.

The rename also moves the calls this package makes into `encryptor`, because
enc-ADR-0009 renames the names they use. These are not this package's names
and are not counted above:

| Call site (at `ad08848`) | Today | After |
|---|---|---|
| `Encryptor.Ecto.Binary`, `assert_single_profile_vault!/1`; `Encryptor.Ecto.Migrator`, `rotatable!/5` | matches the profile `:tenant` | `:scoped`; `VaultProfileError`'s `:profile` field reports `:scoped` |
| `Encryptor.Ecto.KeyStore`, `tenant_ref/2` (private) | `Encryptor.Envelope.tenant_ref/2` | `Encryptor.Envelope.scope_ref/2` |
| `Encryptor.Ecto.KeyStore`, `wrapped_key/1` and `unwrap_row/4` | builds `%WrappedKey{tenant_ref: _}` and a provisioned row keyed `tenant_ref` | `scope_ref` in both |
| `Encryptor.Ecto.Migrator.Pass`, `against_declaration/2` | `Encryptor.Context.tenant_ref_key/0` | `Encryptor.Context.scope_ref_key/0`, which returns the same `"tenant_ref"` |
| `mix.exs`, `deps/0` | `{:encryptor, "== 0.4.1"}` | the exact pin on the `encryptor` release that ships enc-ADR-0009 |

**3. The persisted and serialized spellings stay.** Each stays byte for
byte, behind the renamed surface that reaches it:

| # | Spelling | What it is | Where this package meets it (at `ad08848`) | Why it stays |
|---|---|---|---|---|
| W1 | column `tenant_ref` | the key store's lookup column | written by the migration `Mix.Tasks.Encryptor.Ecto.Gen.KeyStoreMigration.source/2` generates; queried by `Encryptor.Ecto.KeyStore.rows/3` | it exists in every adopter's database. Renaming it is DDL on a live table in each of them, for a name nothing outside the database reads, and a generator that emitted a new name would create tables the shipped query cannot read. After the rename `rows/3` selects it as `scope_ref: k.tenant_ref`, and both key-store generators are unchanged |
| W2 | the unique index over `(tenant_ref, version)`, which Ecto names `<table>_tenant_ref_version_index` | the race guard on provisioning | `unique_index(:<table>, [:tenant_ref, :version])` in the same generated migration | its name is derived from W1 and lives in the same databases; an adopter's own later migration may name it |
| W3 | context key `"tenant_ref"` | the pair the vault injects into every ciphertext's authenticated context | read, for presence only, by `Encryptor.Ecto.Migrator.Pass.against_declaration/2` | it is `encryptor`'s wire constant (enc-ADR-0009 decision 4, row 1); this package adds no envelope of its own (ADR-0001 decision 11) and cannot change what the vault authenticates |
| W4 | the reference value stored in W1 | the derivation of a host's selector under the reference subkey | computed by `Encryptor.Ecto.KeyStore`'s private `tenant_ref/2` through the vault | enc-ADR-0009 decision 4 pins the derivation: `scope_ref/2` returns what `tenant_ref/2` returned, so every stored row is still found |
| W5 | root purpose `"tenant-ref"` | the purpose a host expands its reference subkey under | the configuration example in `Encryptor.Ecto.KeyStore`'s moduledoc and its option table | `encryptor`'s wire constant (enc-ADR-0009 decision 4, row 6); a host that passed another string would derive a different reference and find no rows |
| W6 | the values `"encryptor-tenant"` and `"t/<ref>/v<n>"` in the key store's `namespace` and `name` columns | a wrapped key's namespace and name | stored by the host's provisioning, read by `rows/3` and compared byte for byte by the vault | `encryptor`'s wire constants (enc-ADR-0009 decision 4, rows 5 and 2); this package neither writes nor rewrites them |

Three stored things carry no owner noun, so the rename cannot touch them:
the blind index's derivation input (`Encryptor.Ecto.BlindIndex.Derivation.info/1`,
under `@info_prefix`, has no component for the `derive:` value, so no stored
index value changes); the migrator's checkpoint row (`Encryptor.Ecto.Migrator.Checkpoint.record/5`);
and the ciphertext bytes, which this layer stores verbatim.

**4. The test-support module is `Encryptor.Ecto.ScopeSetup`, its macro is
`setup_scope/1` and its function is `put_scope/1`.** `Scope` is taken by the
process store (row 1) and `ScopeContext` by the behaviour (row 2).
`scope/1` is taken by the plan DSL (row 11), and both macros sit in the
same exported formatter list (row 14). The one constraint the macro carries
is that it expands to `setup` and never `setup_all`, so the name says what
it expands to. With the blind index's word moved to `derive:` (row 17), every
remaining `scope` in the option vocabulary means the key's owner.

**5. The blind index's option is `derive: :per_scope | :global`.** The option
says how the index key is derived, not whose it is: `:per_scope` derives it
from the resolved scope's key material, `:global` from the vault's single
key. The default is unchanged: a field that resolves a scope gets
`:per_scope`, and a `scope: :none` field must still write `derive: :global`
out loud (ADR-0003 decision 3c).

**6. The default strategy's value is `:process`.** It names what the
strategy reads, the process store, and matches the module that implements it
(row 3). The plan DSL keeps refusing that value, as it refuses `tenant :scope`
today (`Encryptor.Ecto.Migration`, `scope_tenant_message/1`): a migrator pass
supplies the scope per row (ADR-0002 decision 3).

**7. The rename is a clean break: no deprecated aliases, and no refusal that
names the old spelling.** Three reasons. `encryptor` made the same choice
for its half (`changelog.d/enc-8cl.md` at `9ad74e2`), and this package pins
`encryptor` exactly, so a host taking the renamed release takes the vault's
break with it. The README's pre-1.0 notice already says a minor release may
rename modules, callbacks and error vocabulary with no compatibility shim.
And every stale spelling already fails loudly through a closed set that
exists today: a stale type option through `Encryptor.Ecto.Binary`'s
unknown-option refusal, a stale blind-index option through
`Encryptor.Ecto.BlindIndex.Declaration`'s `validate_options!/2`, a stale
migrator option through `Encryptor.Ecto.Migrator`'s `unknown!/1`, a stale
flag through `Encryptor.Ecto.Migrator.CLI`'s strict parse, and a stale DSL
macro or module as an undefined function. The filters are the case that
matters: an `--only-tenant` that was silently ignored would widen a write run
to every scope. The rename's acceptance pins, with a test each, that the old
filter option and the old flag are refused and start no pass.

**8. After the rename, the owner noun in `lib/` is only decision 3's
spellings and the text that explains them.** A reader who finds `tenant`
next to `scope` finds the reason beside it, as enc-ADR-0009 decision 6 asks
of the vault.

## Consequences

- The rename is a **breaking** change and ships in a minor release with a
  Breaking changelog entry per surface. A host changes its type modules
  (`tenant:` to `scope:`, `:scope` to `:process`), its blind index
  declarations (`scope:` to `derive:`, `:tenant` to `:per_scope`), its calls
  to the process store and the test helper, its resolver's `@behaviour`, its
  migration plans (`tenant_from` to `scope_from`), its migrator invocations,
  and any match on an exception's `:tenant` field or on a renamed reason. It
  changes nothing it has stored and runs no data migration.
- Every row written before the rename reads after it: the ciphertexts,
  because nothing the vault authenticates changes (W3); the wrapped keys,
  because the column, its index and the reference are unchanged (W1, W2,
  W4); the blind index values, because the derivation has no component the
  rename touches.
- The key store's in-memory row and its column spell one value two ways
  (row 30, W1), which is the cost of not migrating adopters' tables.
- The implementation is scheduled after the `encryptor` release that ships
  enc-ADR-0009 is available, because the call-site table names functions and
  a struct field that exist only from that release on.

## The contract as typespecs

As the rename is to spell them; a proposal, not landed code.

```elixir
# Encryptor.Ecto.Binary
@type opts :: [
        vault: module(),
        scope: :process | :none | module(),
        context: %{optional(String.t()) => String.t()},
        legacy: module(),
        table: String.t(),
        column: String.t()
      ]

# Encryptor.Ecto.ScopeContext
@callback resolve(operation(), params()) ::
            {:ok, String.t()} | :none | {:error, term()}

# Encryptor.Ecto.ScopeContext.Process
@spec resolve(ScopeContext.operation(), ScopeContext.params()) ::
        {:ok, String.t()} | {:error, :no_scope_in_process}

# Encryptor.Ecto.BlindIndex.Derivation
@type derive :: :per_scope | :global
@type selector :: {:scope, String.t()} | :global

# Encryptor.Ecto.Migrator.Plan
@type scope :: {:column, atom()} | :none | module()

# Encryptor.Ecto.KeyStore
@type row :: %{
        scope_ref: String.t(),
        version: pos_integer(),
        namespace: String.t(),
        name: String.t(),
        bits: 256,
        wrapped: binary(),
        wrapping_shape: String.t(),
        key_id: String.t() | nil
      }
```

## Worked example: a host's declarations before and after

Before the rename:

```elixir
defmodule Library.Encrypted.Binary do
  use Encryptor.Ecto.Binary, vault: Library.ScopedVault
end

schema "patrons" do
  field :email, Library.Encrypted.Binary
  field :email_index, :binary
  blind_index :email, :email_index, scope: :tenant, normalize: :email
end

Encryptor.Ecto.Tenant.wrap("branch_north", fn -> Repo.insert!(changeset) end)
```

After it:

```elixir
defmodule Library.Encrypted.Binary do
  use Encryptor.Ecto.Binary, vault: Library.ScopedVault
end

schema "patrons" do
  field :email, Library.Encrypted.Binary
  field :email_index, :binary
  blind_index :email, :email_index, derive: :per_scope, normalize: :email
end

Encryptor.Ecto.Scope.wrap("branch_north", fn -> Repo.insert!(changeset) end)
```

The type module needs no edit because it never wrote the option: the default
strategy is the process store under either name. The index row written
before the upgrade is found by a `where_eq/3` built after it, because the
derivation input is the same string. The ciphertext beside it decrypts
because its context still carries `"tenant_ref"`. A migration run narrowed
the old way fails before its first batch:

```
mix encryptor.ecto.migrate Library.PatronsPlan --mode write --only-tenant branch_north
# refused by the strict parse: --only-tenant is not a known switch
```

## Open questions

None. enc-ADR-0009's open question on deprecated aliases is answered for this
package by decision 7.

## Note (2026-09-24): the operator accepted this record

The Status line at the head of this file now reads `accepted (2026-09-24)`,
and the index row in `docs/adr/README.md` says the same. The rename this
record decides shipped in `encryptor_ecto` 0.6.0 on Hex, the commit tagged
`v0.6.0` (`cf4fd54`), which pins `encryptor` `== 0.5.0`, the release that
ships enc-ADR-0009.

Three passages speak from before the rename. None is edited; each is read with
this Note:

- Decision 1's "The rename is later, scheduled work; this record decides its
  names, and nothing in `lib/` changes with it." True of the commit that
  added this record; the rename landed after it and ships in 0.6.0.
- "The contract as typespecs" opens "As the rename is to spell them; a
  proposal, not landed code." It is landed code now, and each type there
  matches `lib/` at `cf4fd54`.
- The "Today (at `ad08848`)" column of decision 2's table and the "Today"
  column of the call-site table name spellings `lib/` no longer carries.

Every claim was re-verified immediately before the flip against main at
`cf4fd54`:

- Decision 2. For each row of the rename table, the new spelling is defined
  where the table's last column says, and the old spelling is absent from
  `lib/` and `.formatter.exs`. The call-site table holds: the profile matched
  is `:scoped`, the key store calls `Encryptor.Envelope.scope_ref/2` and builds
  `%WrappedKey{scope_ref: _}`, the pass calls
  `Encryptor.Context.scope_ref_key/0`, and `mix.exs` pins `{:encryptor, "==
  0.5.0"}`. `[:encryptor_ecto, :legacy_load]`'s metadata is still `:table` and
  `:column` (`Encryptor.Ecto.Binary`, `emit_legacy_load/1`). The comments in
  `.quality.exs` and `coveralls.json` name `Encryptor.Ecto.ScopeContext`, and
  neither `key_ring: "encryptor-tenant-keys"` nor `MyApp.TenantVault` is left
  in the README, `docs/guides/`, `docs/explanation/` or `lib/`.
- Decision 3. `rows/3` selects `scope_ref: k.tenant_ref`
  (`Encryptor.Ecto.KeyStore`); both key-store generators are byte-identical
  between `ad08848` and `cf4fd54`; the moduledoc's configuration example still
  expands `"tenant-ref"`; `"tenant_ref"` is still the context key the pass
  compares for presence (`Encryptor.Ecto.Migrator.Pass`).
- Decision 7. The old migrator options are refused and start no pass
  (`test/encryptor/ecto/migrator_run_test.exs`), and so are the old flags
  (`test/mix/tasks/encryptor_ecto_migrate_test.exs`).
- Decision 8. Every `tenant` left in `lib/` is one of decision 3's spellings
  or text about the kept column. The key-store generator's moduledoc still
  describes its table as "one row per tenant per key version", around the
  `tenant_ref` column and the `{tenant_ref, version}` index; decision 3 keeps
  both generators unchanged, and this Note reads those sentences as text
  about W1 and W2.
- Consequences. The 0.6.0 changelog carries a `### **Breaking**` section for
  the rename.

Provenance: bead ece-60gg.
