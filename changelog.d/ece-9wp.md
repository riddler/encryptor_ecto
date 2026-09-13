### Added

- `mix encryptor.ecto.gen.key_store_shape_migration` writes the additive
  migration that adds `wrapping_shape` and `key_id` to a wrapped-key table an
  earlier version created, backfilling every existing row as an engine message.
- A wrapped-key row declares which kind of wrapping it holds in its own
  `wrapping_shape` column, and `Encryptor.Ecto.KeyStore` picks the unwrap path
  from it per row, so a store can hold engine messages and GCP KMS ciphertexts
  at once instead of guessing (ADR-0005).

### Changed

- **Breaking.** `Encryptor.Ecto.KeyStore` now selects `wrapping_shape` and
  `key_id`, which a table created before this version does not have, and a
  store reading one fails every lookup as `{:key_unavailable, selector}` until
  it does. Run `mix encryptor.ecto.gen.key_store_shape_migration`, review the
  file it writes, and `mix ecto.migrate` it *before* deploying this version,
  not after. A table created by `mix encryptor.ecto.gen.key_store_migration` at
  this version already has both columns and needs nothing.
- Host code that inserts wrapped-key rows must set `wrapping_shape`:
  `"engine_message"` for a wrapping the root vault produced, or
  `"gcp_kms_ciphertext"` with the `key_id` it was produced under. The column
  has no default once the migration finishes, so a forgotten shape is a write
  that fails rather than a row that lies about itself.
