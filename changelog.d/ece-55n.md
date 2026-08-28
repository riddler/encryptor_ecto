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
