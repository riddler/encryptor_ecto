# Quality configuration for encryptor_ecto.
#
#   mix quality                 - full gate: format, compile, credo, dialyzer,
#                                 deps audit, full test suite with coverage.
#                                 Run before every commit.
#
#   mix quality --profile loop  - inner loop while implementing: skips dialyzer
#                                 and coverage, runs only the tests covering
#                                 changed code. Use between edits.
#
# Agents: prefer `--format json --report -` when you want to route on results.
#
# Deliberately smaller than statifier-ex's gate. That repo's custom stages -
# the gate guard, the ADR guard and judge, the regression ratchet - all exist
# to protect a conformance corpus this package does not have, and to police an
# ADR set large enough to need policing. "Corpus" there means a body of
# recorded fixture cases a ratchet can hold a pass/fail baseline over; the
# provider conformance suite this package does run
# (test/encryptor/ecto/key_store_conformance_test.exs, which `use`s
# encryptor's shared behaviour suite directly) is a different thing -
# properties compiled into the ordinary test run, with no recorded case list
# for a ratchet to count. Adopting any of them here is a decision to record
# when there is something for it to protect, not a default to inherit.
#
# There is deliberately no .credo.exs either: credo's own defaults under
# --strict are the gate until this package has a reason to deviate from one.
#
# Recorded deviation from the satellite shape - coveralls.json carries
# "treat_no_relevant_lines_as_covered": true on top of the shared
# minimum_coverage: 90. The flag is display-only as this package stands, and
# the earlier claim here that it kept the gate off the 90% floor no longer
# holds: excoveralls checks minimum_coverage against the run TOTAL, and a file
# with zero relevant lines contributes nothing to that total either way. It
# did hold for the moduledoc-only scaffold this package began as - when the
# run's total relevant lines are themselves 0, excoveralls returns the flag's
# default value AS the total (100.0% with the flag, 0.0% without), so the flag
# alone decided pass or fail against the 90% floor. Measured on this package
# at 2026-09-13: 95.4% with the flag on and 95.4% with it off, green both
# times.
# What the flag does change is the per-file column for the two modules that
# compile no executable lines - Encryptor.Ecto (moduledoc only) and
# Encryptor.Ecto.ScopeContext (typedocs and one @callback) - which read
# 100.0% with the flag and 0.0% without it. It is kept so those two rows do
# not read as uncovered code. Carried from the same deviation statifier_blocks
# recorded under sb-p6s.

[
  format: [
    check: true
  ],
  compile: [
    warnings_as_errors: true
  ],
  credo: [
    strict: true
  ],
  # The two documentation stages make this gate the pre-publish check for the
  # package's docs. The Docs stage runs `mix docs` and fails on any ExDoc
  # warning. The doc_links stage fails on the link rules ExDoc accepts
  # silently: a README relative link to a file not in the package files, a
  # relative link in a Markdown extra to a file that is not itself an extra
  # (moduledoc links are the Docs stage's), two extras sharing a basename, and
  # a silent rewrite of a link to a different extra.
  # They are a deliberate enlargement of this gate: a broken link on HexDocs
  # or hex.pm is a defect in what this package publishes, and nothing else
  # here catches it before the publish does.
  docs: [
    enabled: :auto
  ],
  doc_links: [
    enabled: :auto
  ],
  profiles: [
    loop: [
      stages: [:format, :compile, :credo, :test],
      test: [scope: :changed, coverage: false]
    ]
  ]
]
