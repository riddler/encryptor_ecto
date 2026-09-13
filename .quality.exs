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
# ADR set large enough to need policing. Adopting any of them here is a
# decision to record when there is something for it to protect, not a default
# to inherit.
#
# There is deliberately no .credo.exs either: credo's own defaults under
# --strict are the gate until this package has a reason to deviate from one.
#
# Recorded deviation from the satellite shape - coveralls.json carries
# "treat_no_relevant_lines_as_covered": true on top of the shared
# minimum_coverage: 90. The flag is display-only, and the earlier claim here
# that it kept the gate off the 90% floor was wrong: excoveralls checks
# minimum_coverage against the run TOTAL, and a file with zero relevant lines
# contributes nothing to that total either way. Measured on this package at
# 2026-09-13: 95.4% with the flag on and 95.4% with it off, green both times.
# What the flag does change is the per-file column for the two modules that
# compile no executable lines - Encryptor.Ecto (moduledoc only) and
# Encryptor.Ecto.TenantContext (typedocs and one @callback) - which read
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
  profiles: [
    loop: [
      stages: [:format, :compile, :credo, :test],
      test: [scope: :changed, coverage: false]
    ]
  ]
]
