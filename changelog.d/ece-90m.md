### Added

- `Encryptor.Ecto.Migrator.Source` is the behaviour a migration plan's `from:`
  names: one `load/2` callback that reads a column's pre-migration value and
  returns `{:ok, plaintext}` or `{:error, reason}` rather than raising.
- `Encryptor.Ecto.Migrator.Source.EctoType` adapts any module that can already
  read those bytes - a plain `Ecto.Type` with `load/1`, which is every
  `cloak_ecto` type module and every hand-rolled one, or an
  `Ecto.ParameterizedType` with `load/3` - so migrating off a prior encryption
  scheme needs no dependency on the library being left behind.
- A failed legacy read is data rather than an exception: an `:error` return and
  a raise from the adapted module both become `{:error, reason}`, scoped to the
  one row, so the migrator can classify the row instead of losing the pass.
- A zero-arity function returned by a source is invoked once and its result is
  the plaintext, so a legacy type that defers its decrypt migrates the value
  rather than the closure.
- `Encryptor.Ecto.Migrator.Source.Plaintext` reads a column that was never
  encrypted, for the backfill leg of adopting encryption on one.
- A `from:` module that can read nothing fails at `mix compile` with an error
  naming the field, rather than on the first row of a live pass.
