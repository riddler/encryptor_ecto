### **Breaking**

- **Breaking.** This version requires `encryptor` 0.6.0 exactly, whose vaults
  refuse to start on an option they do not read, where 0.5.0 ignored it: the
  refusal is `{:invalid_config, layer, {:unknown_options, keys}}`. Rename or
  remove each listed option in your vaults' configuration; `encryptor`'s own
  0.6.0 changelog lists the rest of what that version changes.
- **Breaking.** `Encryptor.Ecto.KeyStore` answers a `"gcp_kms_ciphertext"`
  row whose `Decrypt` Cloud KMS refuses with HTTP 400 or 404 - a destroyed or
  disabled key version, a key that is not there, a row moved to another
  scope - as `{:invalid_key_descriptor, {:kms_refused, status}}`, where it
  answered `{:key_unavailable, selector}`; the store passes the provider's
  answer through unchanged. An IAM denial (403), a throttle, a server error
  and an unreachable service still answer `{:key_unavailable, selector}`.
  Match the new term wherever you handled such a row as `:key_unavailable`,
  and stop retrying it.
