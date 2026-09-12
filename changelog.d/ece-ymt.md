### Changed

- A migration pass recognises an already-migrated row from its message header
  instead of decrypting it, so a resumed or repeated run over a mostly
  migrated table no longer spends a decrypt per row it is going to skip. A
  verification (`mix encryptor.ecto.verify`) still opens every row it counts.

### Added

- `Encryptor.Ecto.Binary.declared_context/1` returns the encryption-context
  pairs a field declaration composes, names and values.
