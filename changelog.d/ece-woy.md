### Added

- `Encryptor.Ecto.KeyStore` starts without `:root_vault` when `:gcp_kms` is
  set, so a table holding only `"gcp_kms_ciphertext"` rows needs no root
  vault. A store configured with neither is still refused as
  `{:missing_config, [:provider, :root_vault]}`. An `"engine_message"` row
  met by a store without a root vault answers
  `{:invalid_key_descriptor, {:no_root_vault, "engine_message"}}`.
