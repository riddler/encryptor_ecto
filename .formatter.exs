# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],

  # `scope_tenant "merchant_7f3"` reads as a declaration rather than a call,
  # the way `field` and `setup` do, so it keeps its parens off. Exported so a
  # host adding `import_deps: [:encryptor_ecto]` gets the same form its tests
  # are documented with, instead of the formatter rewriting every call site.
  locals_without_parens: [scope_tenant: 1],
  export: [locals_without_parens: [scope_tenant: 1]]
]
