### Added

- `Encryptor.Ecto.BlindIndex.Derivation` derives a blind index's key through
  the vault's `derive/3`: the index tree is a salted subkey under the vault's
  reserved `"encryptor/v1/blind-index"` label, and the table, column, index
  name and version are the info string inside it, so an index key can never be
  an encryption key and two columns holding the same plaintext produce
  unrelated index values.
- Index keys are salted with the vault's per-deployment `:derivation_salt`,
  so two deployments provisioned from the same key material - a restored
  backup, a cloned staging environment - derive unrelated index values, and a
  vault without one refuses to derive rather than deriving under nothing.
- Key material never reaches this package: there is no argument on any
  function in the derivation that a tenant master key could be passed as, and
  every byte comes back from the vault already derived.
- A blind index resolves its tenant through the encrypted field's own
  configured strategy, so a host that replaced the default with a resolver
  module gets the same replacement for its indexes, and a missing tenant
  raises `MissingTenantError` rather than silently matching nothing.
- `Encryptor.Ecto.BlindIndex.DerivationError` reports a derivation that could
  not proceed, naming the table, column, index name and version, and never a
  value.
