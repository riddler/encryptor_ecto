### Fixed

- `Encryptor.Ecto.Migrator.verify/2` no longer reports an unmigrated row as
  already in the target state when the plan's `to:` type module declares
  `legacy:`. The migrator now loads its target without the legacy reader, so
  the runbook's plan - whose `to:` is the host's own type module, `legacy:`
  set for the whole window - verifies red until every row is rewritten.
