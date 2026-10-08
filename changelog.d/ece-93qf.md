### Changed

- Requires `encryptor` 0.8.0, which runs on `aws_encryption_sdk` 1.1: a vault's required pairs (every scoped field's `"scope_ref"`, and the keys in `:required_context`) are bound to each message without being stored in its header, so `Encryptor.Message.describe/1` no longer shows them. Rows written earlier still load. A node still on an earlier version cannot read a row the new version writes with required context, so upgrade every node that reads a column before any node writes it.

### Fixed

- `Encryptor.Ecto.Migrator.run/2` recognises a row written through `encryptor` 0.8.0 as already in the target state: its header probe no longer expects the header to store a pair the target's vault requires, which would have counted every such row migratable on a dry run and sent it to the source reader, to be reported undecryptable, on a write run. A header that leaves such a pair out is settled by loading the row; a row written earlier, whose header stores the pairs, is recognised as before.
