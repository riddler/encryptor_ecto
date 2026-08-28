### Added

- `use Encryptor.Ecto.Migration, repo: MyApp.Repo` declares a migration plan:
  `rewrite` per schema, `tenant_from/1` or `tenant/1` for how the tenant is
  resolved, and `field/2` naming the `from:` and `to:` type modules of each
  column. The module compiles to an `Encryptor.Ecto.Migrator.Plan` struct,
  handed over by a generated `__plan__/0`.
- A plan that would fail on row one fails at `mix compile`: every field and
  `into:` column is checked against the schema, `tenant_from` against its
  columns, every `from:` module against the shapes
  `Encryptor.Ecto.Migrator.Source` can read, and every `to:` module against
  the load *and* dump pair it has to answer. Each refusal is a `CompileError`
  naming the schema and field, at the line the plan declared it.
