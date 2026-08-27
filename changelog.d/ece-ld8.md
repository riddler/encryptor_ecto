### Added

- Encrypted-field failures raise a named exception - `MissingTenantError`,
  `MissingContextError`, `EncryptError`, `DecryptError` or
  `SerializationError` - each carrying the declared table, the declared column,
  the encryption-context key names and the upstream reason, and none of them
  carrying a plaintext, a ciphertext or key material in its message or its
  `Inspect` form.
