### Added

- `Encryptor.Ecto.SuspensionStore`, an `Encryptor.Vault.Suspension.Store` over the host's repo: configured as a vault's `suspension_store: {Encryptor.Ecto.SuspensionStore, repo: MyApp.Repo}`, a suspension written on one node is enforced on every node within one poll interval and survives restarts. Its table comes from the new `mix encryptor.ecto.gen.suspension_store_migration`.
- `Encryptor.Ecto.KeyStore.shred/3` deletes a scope's wrapped keys (`version: :all`) or one retired version (`version: n`) from the store a running vault reads, in one transaction, waits out the vault's cache `max_age` unless given `drain: :skip`, and returns an `Encryptor.Ecto.KeyStore.Shred` record of the versions deleted and when the delete took effect. Each shred emits `[:encryptor_ecto, :shred]`.
