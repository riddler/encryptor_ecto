### Added

- `mix encryptor.ecto.gen.plan` writes a migration plan skeleton into the
  host's tree. It loads the host's application, reads every Ecto schema in it,
  and emits one `rewrite` block per schema with one `field` line per field
  whose type is a module rather than a built-in Ecto type. `--repo` is read
  from the app's `:ecto_repos` when that names exactly one; `--app`,
  `--module` and `--output` cover the rest, and the generator never overwrites
  a plan that already exists.
- The generated file **does not compile**, on purpose (ADR-0004 decision 7),
  and carries a comment explaining why so that whoever runs `mix compile` next
  does not read it as a bug. Three facts are left visibly unanswered because a
  generator cannot know them: every block emits `tenant_from
  :TODO_tenant_column`, which the plan DSL rejects at compile time - guessing
  the tenant column re-encrypts every row under one tenant's key, and a
  skeleton that compiled would be a skeleton somebody ran; every field's `to:`
  is a comment rather than a value, since a half-guessed target type produces
  a diff that looks reviewed; and the field list over-reports, because per
  ADR-0004 decision 1 the generator tests for no other library's marker
  function, so a custom type that encrypts nothing is listed too. A false
  positive a human deletes beats a field nobody noticed.
- This is the one member of the task family with no release equivalent
  (ADR-0004 Q6): reading `__schema__(:type, field)` needs the host's schema
  modules loaded, which a Mix task has and a release command does not. It
  writes source into a working tree, which is not a thing a release does.
