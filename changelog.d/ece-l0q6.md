### Changed

- A host upgrading from `encryptor_ecto` 0.9.0 or earlier still holds the suspension rows that earlier whole-scope shreds left behind; a second shred of such a scope answers `{:unknown_key, selector}` before it reaches the row, so clear each one with `Encryptor.Vault.reinstate/2`.
- `Encryptor.Ecto.KeyStore.shred/3` emits no suspension write event when it deletes a scope's suspension row, so a vault that held the scope suspended keeps it suspended until its next poll.
