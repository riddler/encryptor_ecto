### Changed

- `blind_index`'s `:slow` option now runs Argon2id over the normalized value before the HMAC, under the parameters the vault declares in `:slow_hash` and a salt derived per index, per tenant and per deployment - so a `slow: true` index finally costs an attacker one Argon2id hash per guess rather than one HMAC. A column already written under a `slow: true` declaration holds plain-HMAC bytes and is invalidated by this change: reindex it the way a `:normalize`, `:bits` or `:version` change is reindexed, through the two-column dance in `Encryptor.Ecto.BlindIndex`'s rotation notes. A host declaring a slow index also adds `{:argon2_elixir, "~> 4.0"}` to its own dependencies; this package still depends on no native code.

### Security

- A `slow: true` index against a vault that declares no `:slow_hash` now raises `Encryptor.Ecto.BlindIndex.DerivationError` and computes nothing, rather than silently writing plain-cost index values into a column an operator believes is hardened.
