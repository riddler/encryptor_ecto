### Added

- `Encryptor.Ecto.KeyStore` takes a `:prefix` option and routes every query it
  issues to that Postgres schema, so a wrapped-key table placed outside the
  repo's default search path is reachable. Place the table with
  `mix ecto.migrate --prefix`; the generators write no schema name into the
  migration they produce.

### Fixed

- An older wrapped-key version that no longer unwraps no longer blocks writes
  for the whole tenant: `encryption_key/2` unwraps only the newest row, and
  `decryption_keys/2` skips the versions that will not open and answers with
  the ones that will. A tenant whose rows all fail reports exactly what it
  reported before.

### Changed

- A permanent store misconfiguration - a table that was never migrated, a
  `:repo` that is not a repository, columns that are not the ones this version
  reads - now raises the exception that names it instead of being reported as
  a retryable `{:key_unavailable, selector}`. `key_unavailable` is narrowed to
  the conditions a retry can actually resolve: the repo not started, the pool
  or the server unable to answer, a cancelled query. A caller that rescued
  around a resolution failure to retry it should expect the misconfiguration
  to come through.
