### Fixed

- `Encryptor.Ecto.KeyStore.shred/3` with `version: :all` re-checks the scope
  after its delete, so a version provisioned while it ran is deleted too and
  listed in `versions` rather than surviving beside a record that says
  `remaining: []`.
