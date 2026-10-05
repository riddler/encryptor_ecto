---
# The docs manifest the documentation tools read. Generated from the family's manifest
# table: change a key there and regenerate. The two prose lines below may be sharpened.
product: encryptor_ecto
family: foundation
audience: Elixir developers with Ecto schemas whose columns must be encrypted at rest
tone: "plain, second person, no marketing"
terminology:
  use:
    - execution
    - chart
    - document
    - revision
  avoid:
    - "run (noun)"
    - workflow instance
example_world: none
docs_root: docs
quadrants:
  tutorials: docs/tutorials
  how_to: docs/guides
  reference: docs/reference
  explanation: docs/explanation
readme: README.md
reference_generator: ex_doc
publish: hexdocs
contributor_paths:
  - docs/adr
  - docs/plans
  - docs/spikes
  - docs/research
  - docs/design
  - docs/measurements
  - CLAUDE.md
executed_snippets:
  - test/encryptor/ecto/scope_in_jobs_guide_test.exs
  - test/encryptor/ecto/two_vaults_guide_test.exs
readme_max_lines: 250
---

Ecto types and a migrator over encryptor: encrypted columns and blind indexes.
Examples are domain-free: a foundation package teaches no domain.
