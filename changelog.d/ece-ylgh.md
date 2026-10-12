### Fixed

- `Encryptor.Ecto.KeyStore.shred/3` with `version: :all` deletes the scope's suspension row, in the same transaction as its keys, when the vault's suspension store is `Encryptor.Ecto.SuspensionStore` on the key store's repo, so the selector no longer outlives the shred in the suspension table; after the vault's next suspension poll a read of the shredded scope answers `{:unknown_key, selector}`. A suspension store on another repo, or another store module, is left alone, and the host reinstates the scope after the shred.
