### Added

- `legacy:` opens the migration window: name the type module the column was
  read with before, and a row the migration has not reached yet still loads,
  through that module, while every write goes out in the new format. The
  primary load is always attempted first, and the fallback hangs off the
  vault's refusal of the stored bytes alone - a missing tenant or a missing
  required context key raises, because answering a host misconfiguration with
  a successful legacy read turns a configuration bug into a silent year of
  un-migrated rows.
- A load that falls through emits `[:encryptor_ecto, :legacy_load]`, counting
  one, with the table and the column and nothing else. The window is
  per-field, so the pair is what tells a host which of its twelve encrypted
  columns still has a legacy reader open. The counter is a convenience and not
  a proof: it is evidence about traffic rather than about rows, and
  `Encryptor.Ecto.Migrator.verify/2` stays the signal a host drops `legacy:`
  on.
- When both loads fail, the exception raised is the primary
  `Encryptor.Ecto.DecryptError`. The legacy attempt's reason travels in the
  non-contractual `:engine` field, reduced to tags and module names, so a
  legacy reader that prints the bytes it choked on cannot put them into the
  failure a host sees.
