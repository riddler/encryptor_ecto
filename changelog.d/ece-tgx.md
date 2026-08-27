### Added

- `Encryptor.Ecto.TenantScope.scope_tenant/1` scopes an ExUnit case or a single
  `describe` block to a named tenant, so a host's suite meets fail-closed
  tenancy without either a default tenant or six lines of setup per case.
- `Encryptor.Ecto.Tenant` documents the full list of boundaries a host is
  expected to wrap, rather than naming a few of them in passing.
