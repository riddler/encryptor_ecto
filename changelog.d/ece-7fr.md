### Added

- `Encryptor.Ecto.Migrator.verify/2` is the read-only half of a migration: the
  same plan, the same classification, no writes, and a non-zero arm for any
  row that is not already in the target state. It is the acceptance test at
  the end of a rotation, the drift check a host runs on a schedule, and the
  signal that the mixed window has closed and `legacy:` can be dropped.
- `sample:` verifies a random draw of rows per field rather than the whole
  scope, for the scheduled check. The draw is random rather than the first
  rows in key order, because key order is the order a pass writes in and a
  prefix of it is the region a partial pass has already migrated.
- `Encryptor.Ecto.Migrator.Report.verified?/1` is that stricter arm as a
  function: every row `:already_target` or `:null`, and no failures. It counts
  a class it has never heard of against a verification, so a class added later
  cannot arrive as a green report.
- `Encryptor.Ecto.Migrator.Census` renders the SQL an operator or a DBA runs
  with no application and no key material: a format census over a byte prefix
  wide enough to separate two formats whose first byte collides, rotation
  progress for one tenant, and a before/after count showing nothing became
  `NULL` or empty.
