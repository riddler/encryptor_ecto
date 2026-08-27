### Added

- `Encryptor.Ecto.Tenant` holds the current tenant for a unit of work, with
  `wrap/2` restoring the previous scope so a pooled process cannot leak one.
- `Encryptor.Ecto.TenantContext` is the one-callback behaviour a host
  implements to resolve the tenant its own way; the default `:scope` strategy
  is an ordinary implementation of it.
