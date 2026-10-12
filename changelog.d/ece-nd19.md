### Fixed

- A `mode: :dry_run` pass with `resume: true` (`--mode dry-run --resume`) after a completed `mode: :write` pass scans the field from the beginning and reports its counts, instead of answering as a no-op with every count at zero, migratable included. The completion mark counts only in `mode: :write`, where a resume of a completed pass is still a no-op.
- `Encryptor.Ecto.Migrator.run/2` reads the checkpoint row's `counts` as a map whatever the adapter returns for the column, so an adapter that returns JSON as text no longer reads every checkpoint as having no recorded run: a resume under different options is refused, and a `mode: :write` resume of a completed pass is a no-op, as they already were on an adapter that returns a map.
