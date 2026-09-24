### **Breaking**

- **Breaking.** This version requires `encryptor` 0.5.0 exactly, which renames
  the key's owner from *tenant* to *scope*: change `context_profile: :tenant`
  to `context_profile: :scoped` in every vault's configuration. Nothing stored
  changes - every ciphertext, wrapped key and blind index value written before
  this version reads after it, and no data migration runs.
- **Breaking.** The owner noun is now *scope* in this package too, with no
  deprecated aliases: `Encryptor.Ecto.Tenant` is `Encryptor.Ecto.Scope`,
  `Encryptor.Ecto.TenantContext` is `Encryptor.Ecto.ScopeContext`,
  `Encryptor.Ecto.TenantContext.Scope` is
  `Encryptor.Ecto.ScopeContext.Process`, `Encryptor.Ecto.MissingTenantError`
  is `Encryptor.Ecto.MissingScopeError`, and
  `Encryptor.Ecto.Migrator.RowTenant` is `Encryptor.Ecto.Migrator.RowScope`
  with `with_tenant/2` renamed `with_scope/2`. Rename the modules you call,
  and change a resolver's `@behaviour Encryptor.Ecto.TenantContext` to
  `@behaviour Encryptor.Ecto.ScopeContext`; the callback is still `resolve/2`.
- **Breaking.** The test helper `Encryptor.Ecto.TenantScope` is
  `Encryptor.Ecto.ScopeSetup`: `scope_tenant "branch_north"` becomes
  `setup_scope "branch_north"` and `put_tenant/1` becomes `put_scope/1`.
  Update the `import`, and the `import_deps` formatter entry keeps working
  unchanged.
- **Breaking.** The type option `tenant:` on `use Encryptor.Ecto.Binary` and
  every type built on it, `Encryptor.Ecto.Map` included, is `scope:`, and its
  default value `:scope` is `:process`: `tenant: :scope` becomes `scope:
  :process`, `tenant: :none` becomes `scope: :none`, and `tenant:
  MyApp.Resolver` becomes `scope: MyApp.Resolver`. A type module that never
  wrote the option needs no edit. The frozen params key `:tenant` an arity-3
  `from:` module receives is `:scope`.
- **Breaking.** The blind index option `scope:` is `derive:`, and its value
  `:tenant` is `:per_scope`: `scope: :tenant` becomes `derive: :per_scope`
  (still the default) and `scope: :global` becomes `derive: :global`. The
  fields of `Encryptor.Ecto.BlindIndex.Declaration` are `:derive` and
  `:derive_declared?` (were `:scope` and `:scope_declared?`),
  `Encryptor.Ecto.BlindIndex.Derivation`'s field and `new!/1` option are
  `:derive` (was `:scope`), its type `scope/0` is `derive/0`, and a
  derivation's selector `{:tenant, selector}` is `{:scope, selector}`. No
  stored index value changes.
- **Breaking.** The migration plan DSL's `tenant_from :branch_id` is
  `scope_from :branch_id` and `tenant :none` is `scope :none`; `mix
  encryptor.ecto.gen.plan` now emits `scope_from :TODO_scope_column`. The
  migrator options `only_tenants:` and `except_tenants:` are `only_scopes:`
  and `except_scopes:`, and the flags `--only-tenant` and `--except-tenant`
  are `--only-scope` and `--except-scope`. The old option and the old flag are
  refused as unknown before any row is read, never ignored.
- **Breaking.** The exception family's `:tenant` field is `:scope`, and every
  message says `scope` where it said `tenant`. The error reasons are renamed:
  `:no_tenant_in_scope` is `:no_scope_in_process`, `{:tenant_profile_vault,
  vault}` is `{:scoped_profile_vault, vault}`, `:field_declared_tenant_none`
  is `:field_declared_scope_none`, `{:invalid, :scope, :not_tenant_or_global}`
  is `{:invalid, :derive, :not_per_scope_or_global}`, and `{:no_row_tenant,
  op}`, `{:null_tenant_column, op}` and `{:unusable_tenant_column, op}` are
  `{:no_row_scope, op}`, `{:null_scope_column, op}` and
  `{:unusable_scope_column, op}`. `Encryptor.Ecto.VaultProfileError`'s
  `:profile` reports `:scoped`. Update any match on the old terms.
- **Breaking.** `Encryptor.Ecto.KeyStore.row/0`'s `:tenant_ref` key is
  `:scope_ref`, the name `encryptor` 0.5.0 gives the same value. The key-store
  table's `tenant_ref` column and its unique index keep their names, and both
  key-store migration generators are unchanged, so an adopter's table needs no
  migration.
- **Breaking.** The migrator's public structures follow the rename:
  `Encryptor.Ecto.Migrator.Plan`'s `tenant/0` type is `scope/0` and a
  rewrite's `:tenant` key is `:scope`; `Encryptor.Ecto.Migrator.Pass`'s fields
  `:tenant`, `:tenant_column`, `:only_tenants` and `:except_tenants` are
  `:scope`, `:scope_column`, `:only_scopes` and `:except_scopes`, and
  `target_header/0`'s `:tenant_ref?` key is `:scope_ref?`;
  `Encryptor.Ecto.Migrator.Keyset.tenant_filter/4` is `scope_filter/4`; and
  the census `:progress` query's `:tenant` placeholder is `:scope`. Rename any
  code that builds or matches them.
