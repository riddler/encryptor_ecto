# Used by "mix format"
locals_without_parens = [
  setup_scope: 1,
  rewrite: 2,
  scope: 1,
  scope_from: 1,
  field: 2
]

[
  # The test inputs are listed by subdirectory so that the dependencies
  # fetched into test/fixtures/hackney1_host/deps are never formatted. The
  # fixture's own tracked mix.exs and lib/ are still checked.
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib}/**/*.{ex,exs}",
    "test/*.{ex,exs}",
    "test/{encryptor,mix,support}/**/*.{ex,exs}",
    "test/fixtures/hackney1_host/mix.exs",
    "test/fixtures/hackney1_host/lib/**/*.{ex,exs}"
  ],

  # `setup_scope "merchant_7f3"` reads as a declaration rather than a call,
  # the way `field` and `setup` do, so it keeps its parens off. The migration
  # plan DSL is the same case and for a stronger reason: a plan is read as a
  # declaration of what gets rewritten, and ADR-0002 decision 2 writes it
  # paren-free. Exported so a host adding `import_deps: [:encryptor_ecto]`
  # gets the same form its tests are documented with, instead of the
  # formatter rewriting every call site.
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
