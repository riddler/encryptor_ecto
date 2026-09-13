### Changed

- Migrating an in-place declaration edit - a field gaining a `:context` pair,
  or moving between tenant strategies - is documented as two declarations: the
  old declaration is kept as a module of its own and named `from:`, and the
  edited one is `to:`. Naming the same module on both sides no longer
  describes that case, because the source side reads the `from:` type's own
  current declaration and an edited declaration has only one current form. The
  field spec gains no source-side params or context option.
