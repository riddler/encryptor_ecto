### Added

- `mix encryptor.ecto.migrate PLAN --mode dry-run|write` runs a migration plan
  through `Encryptor.Ecto.Migrator.run/2`. `--mode` is required and has no
  default; `--batch-size`, `--resume`/`--no-resume`, `--prefix`,
  `--no-checkpoint`, `--only Schema:field`, `--only-tenant`,
  `--except-tenant` and `--on-error halt|continue` each map onto one option of
  `run/2` and add no capability the library function lacks.
- `mix encryptor.ecto.verify PLAN [--sample N|all] [--prefix PREFIX]` runs the
  read-only pass. Those two flags and no others: a migrate flag passed here
  refuses and names the verb it belongs to, rather than being silently
  ignored by a `verify/2` that has no such option.
- `mix encryptor.ecto.gen.migration` writes the checkpoint table's migration
  into the host's tree - `--table` renames it, `--migrations-path` places it.
  It issues no DDL and never overwrites an existing migration for the table;
  the host reviews the file, commits it, and runs it with its own
  `mix ecto.migrate`.
- The tasks carry the flag tables and the exit codes in their `@moduledoc`s,
  which are the reference half of the documentation set. Exit codes: `0` the
  pass completed with no failures, `1` the pass ran and found something (a dry
  run that finds `:undecryptable` rows included), `2` a usage error, a plan
  that will not compile, or a run that could not start.
