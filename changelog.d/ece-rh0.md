### Added

- `Encryptor.Ecto.Integer`, `Encryptor.Ecto.Float`, `Encryptor.Ecto.Date`,
  `Encryptor.Ecto.Time`, `Encryptor.Ecto.NaiveDateTime` and
  `Encryptor.Ecto.DateTime` encrypt a scalar field through the same vault call
  and the same closed option set as `Encryptor.Ecto.Binary`, casting with
  Ecto's own caster and storing the value's textual form.
