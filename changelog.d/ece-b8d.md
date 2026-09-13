### Fixed

- A migration plan whose `from:` is one of this package's own encrypted types
  now reads its rows: the migrator builds that side's params from the type's
  own declaration, under the plan's tenant strategy, instead of handing it the
  identifying map an unknown legacy reader gets, which every such row used to
  raise on and report `:undecryptable`.
