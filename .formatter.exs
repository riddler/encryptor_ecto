# Used by "mix format"
locals_without_parens = [
  scope_tenant: 1,
  rewrite: 2,
  tenant: 1,
  tenant_from: 1,
  field: 2
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],

  # `scope_tenant "merchant_7f3"` reads as a declaration rather than a call,
  # the way `field` and `setup` do, so it keeps its parens off. The migration
  # plan DSL is the same case and for a stronger reason: a plan is read as a
  # declaration of what gets rewritten, and ADR-0002 decision 2 writes it
  # paren-free. Exported so a host adding `import_deps: [:encryptor_ecto]`
  # gets the same form its tests are documented with, instead of the
  # formatter rewriting every call site.
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
