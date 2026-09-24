### Fixed

- `Encryptor.Ecto.Migrator.verify/2` no longer reports an unmigrated row as
  already in the target state when the plan's `to:` type module declares
  `legacy:`. The migrator now loads its target without the legacy reader, so
  the runbook's plan - whose `to:` is the host's own type module, `legacy:`
  set for the whole window - verifies red until every row is rewritten.
- `Encryptor.Ecto.Migrator.run/2` no longer returns `{:ok, report}` having
  written nothing when the target's vault is not running and the plan's `to:`
  declares `legacy:`. Every legacy row used to be counted `already_target`
  through the target's legacy reader; each is now a recorded failure, and the
  pass returns `{:error, report}`.
