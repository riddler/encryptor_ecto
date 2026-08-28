### Added

- A migration plan field may declare `source_authenticated: false`, which
  acknowledges that its legacy cipher has no authentication tag: a wrong key
  or a corrupt row decrypts to something rather than failing, so a successful
  load is not evidence. Its rows are then counted `:migratable_unverified`
  rather than `:migratable`, in a dry run, a write and a verification alike,
  so no report claims a verification that never happened.
- `validate:` takes a host-supplied `(term() -> boolean())` applied to the
  loaded plaintext before it is re-encrypted - a card number is sixteen
  digits, a serialized map parses, a kept legacy hash column recomputes. A row
  it rejects is `:undecryptable` and is not written. There is no built-in
  generic validator: a printable?/UTF-8? check would be reassurance rather
  than a control, and only the host knows what its own values look like.
- `Encryptor.Ecto.Migrator.Report.classes/0` gains `:migratable_unverified`,
  which counts against `verified?/1` like every class but `:null` and
  `:already_target`.

### Changed

- `mode: :write` is refused, before a row is read, for a field that declares
  `source_authenticated: false` without a `validate:`. `mode: :dry_run` and
  `verify/2` still run it, which is how such a field is inspected first.
- A plan field whose `from:` type is not one of this package's own
  vault-backed types must now declare `source_authenticated:` explicitly, and
  fails at `mix compile` naming the schema and field if it does not. Silence
  is allowed only where authentication is provable - the context-change case,
  where `from:` names a type this package wrote the bytes with. Everywhere
  else `from:` is the host's own legacy reader, and this package cannot tell
  an AEAD cipher from a stream cipher by looking, so it asks where the
  question is cheap. Upgrading hosts declare `source_authenticated: true` per
  legacy field: the reviewable assertion that someone checked.
