### Added

- `Encryptor.Ecto.Migrator.run/2` takes `writing_key:`, the name of the
  wrapping key the rows in scope are supposed to claim, which makes a single
  tenant's data-key rotation rewrite the rows a pass without it left alone.
