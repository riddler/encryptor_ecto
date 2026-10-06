### **Breaking**

- A field or a wrapped key written under encryptor 0.6.x or earlier does not
  open under this version, which requires encryptor 0.7.0 (encryptor's
  ADR-0009 Amendment A, A3): a host holding such rows stays on
  encryptor_ecto 0.7.x, since neither package ships a re-encrypt. A host also
  expands its `:reference_subkey` under `"scope-ref"` from now on;
  `Encryptor.Envelope.root_subkey/2` in encryptor 0.7.0 still accepts
  `"tenant-ref"`, so a subkey left on the old purpose raises no error, and
  the call that derives it has to be changed by hand.

### Changed

- Requires encryptor 0.7.0, the vault's wire format v2: the pin moves from
  `encryptor == 0.6.1` to `encryptor == 0.7.0`, and the reference subkey a
  host passes as `:reference_subkey` is expanded under the root purpose
  `"scope-ref"`, which encryptor 0.7.0 names in place of `"tenant-ref"`.
