### Changed

- Requires encryptor 0.7.0, the vault's wire format v2: the pin moves from
  `encryptor == 0.6.1` to `encryptor == 0.7.0`, and the reference subkey a
  host passes as `:reference_subkey` is expanded under the root purpose
  `"scope-ref"`, which encryptor 0.7.0 names in place of `"tenant-ref"`.
