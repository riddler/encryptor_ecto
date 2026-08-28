### Added

- `Encryptor.Ecto.BlindIndex.blind_index/3` declares a keyed blind index on an
  encrypted field, inside the schema beside the column it indexes. The
  declaration is the one place an index's normalization and key derivation
  live, so the helper that writes the column and the helper that queries it
  cannot disagree about either.
- `Encryptor.Ecto.BlindIndex.Normalizer` ships the founding set - `:none`,
  `:trim`, `:downcase`, `:email`, `:digits`, and a host `{module, function}`.
  The built-ins are total on every binary, including one that is not valid
  UTF-8; a host normalizer that raises, throws, exits, is not exported, or
  returns a non-binary produces `NormalizationError` naming the table, the
  column and the index, and no value.
- `Encryptor.Ecto.BlindIndex.Declaration` is the read surface a helper
  resolves an index through: `list/1`, `fetch!/3`, `derivation!/1` and
  `normalize!/2`.
- Declaring a blind index on a `tenant: :none` field with no `:scope`, or with
  `scope: :tenant`, is a compile error. `scope: :global` is the only
  possibility there and it still has to be written, because the reviewer
  reading that schema line is the person who needs to know the column is
  cross-tenant correlatable and survives a tenant shred.
- Declaring one on a field this package does not encrypt is a compile error,
  as are an index column that is not a field on the schema, an index column
  that is itself encrypted, and two declarations sharing an index name or a
  `{source, column}` pair.

### Fixed

- `Encryptor.Ecto.String` and `Encryptor.Ecto.Map` fields now carry the marker
  that identifies an encrypted field, so `Encryptor.Ecto.Declarations` sees
  them. Its uniqueness check previously covered only `Encryptor.Ecto.Binary`
  fields, which meant a text or map field sharing a declared `{table, column}`
  pair with another field passed a check whose whole purpose is to deny that
  pairing - the two are mutually substitutable, since both ride the declared
  pair as AAD through the same code.
