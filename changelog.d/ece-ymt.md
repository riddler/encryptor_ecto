### Changed

- A migration pass recognises already-migrated rows from their message
  headers, so a resumed or repeated run over a mostly migrated table spends
  one decrypt per wrapping key per batch instead of one per row it is going
  to skip. A row is only recognised this way once a load has proven the
  target reads that key, so a rewrite whose source differs in vault, key,
  algorithm suite or encryption context still rewrites every row. A
  verification (`mix encryptor.ecto.verify`) still opens every row it counts.

### Added

- `Encryptor.Ecto.Binary.declared_context/1` returns the encryption-context
  pairs a field declaration composes, names and values.
