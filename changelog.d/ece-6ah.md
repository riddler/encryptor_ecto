### Added

- `Encryptor.Ecto.KeyStore` takes a `:gcp_kms` option carrying `Encryptor.Provider.GcpKms`'s configuration, and with it serves `"gcp_kms_ciphertext"` rows that it previously refused as `{:invalid_key_descriptor, {:unsupported_wrapping_shape, "gcp_kms_ciphertext"}}`; a store configured without the option still refuses them the same way.
