### Fixed

- A migration plan field with no `source_authenticated:` whose vault-backed `from:` type fails on the second `init/1` call now raises a `CompileError` with the plan's file and line, naming the field, where it raised the type's own bare exception.
