### Added

- A field declared `tenant: :none` must name a `:single`-profile vault, and
  pairing one with a `:tenant`-profile vault now raises
  `Encryptor.Ecto.VaultProfileError` naming the field, the vault and the
  profile - instead of surfacing on the first write as whatever the vault's
  key provider happens to refuse first, which names neither.
- `Encryptor.Ecto.Binary`'s documentation states at the option itself what
  `tenant: :none` costs: those ciphertexts are not crypto-shreddable with a
  tenant key.
