### Added

- `Encryptor.Ecto.BlindIndex.Derivation` derives a blind index's key: the
  index tree is a subkey under the vault's reserved
  `"encryptor/v1/blind-index"` label, and the table, column, index name and
  version are the info string inside it, so an index key can never be an
  encryption key and two columns holding the same plaintext produce unrelated
  index values.
- A blind index resolves its tenant through the encrypted field's own
  configured strategy, so a host that replaced the default with a resolver
  module gets the same replacement for its indexes, and a missing tenant
  raises `MissingTenantError` rather than silently matching nothing.
- `Encryptor.Ecto.BlindIndex.DerivationError` reports a derivation that could
  not proceed, naming the table, column, index name and version, and never a
  value.
