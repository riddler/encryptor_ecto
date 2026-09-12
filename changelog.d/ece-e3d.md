### Added

- `Encryptor.Ecto.KeyStore` resolves a vault's tenant selectors against a
  wrapped-key table, so per-tenant keys come from the database instead of from
  configuration.
- `mix encryptor.ecto.gen.key_store_migration` writes that table's migration
  into the host's tree, to review and run like any other migration.
