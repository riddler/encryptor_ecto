### Added

- `Encryptor.Ecto.Migrator.run/2` rewrites the ciphertext columns a plan names,
  against live traffic: every row is probed before it is rewritten, so running
  the pass twice, resuming it from the wrong cursor or interrupting it midway
  all converge on the same end state.
- Writes are compare-and-swap against the exact bytes the migrator read, so a
  row the application wrote in the meantime is counted as concurrently
  migrated rather than clobbered with a re-encryption of stale plaintext.
- Rows are visited in primary-key order with keyset pagination, one batch per
  transaction, with the batch's cursor and counts recorded in the same
  transaction. Single-column integer and binary primary keys are supported;
  a composite or otherwise unordered key is refused with a message naming the
  schema rather than paged over under a guess.
- The checkpoint key carries the schema prefix, so a host looping `run/2` over
  its prefixes gets one cursor per prefix instead of the second prefix
  resuming at the first's and skipping every row below it.
- `mode:` is required and has no default: `:dry_run` rehearses every read,
  probe, decrypt and encrypt and discards the write, `:write` performs it.
- A missing checkpoint table is refused with a message naming the generator -
  this package issues no DDL - and `checkpoint: :none` runs the documented
  degraded mode with no checkpoint at all.
- Failures are loud and the default is to stop: an unreadable row halts the
  pass, rolls back its batch, and reports the primary key, the schema, the
  field and a reason that carries no plaintext, ciphertext or key material.
  `on_error: :continue` records it and finishes, and still exits non-zero.

### Changed

- ADR-0004 gains a dated proposed amendment answering Q2 on the operator's
  ruling: silence about `source_authenticated:` is allowed only where
  authentication is provable from the `from:` type, and every other `from:`
  must declare it explicitly. Decision 3d's worked example changes with it.
  The compile-time enforcement is a later bead's; only the record's text lands
  here.
