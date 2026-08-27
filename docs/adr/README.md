# Architecture Decision Records

| # | Decision | Status |
|---|---|---|
| [0001](0001-vault-backed-ecto-types.md) | cloak_ecto-shaped vault-backed types, with tenant context from an explicit process scope | accepted (2026-08-27, with amendments) |
| [0002](0002-migrator.md) | The migrator: a plan-driven, resumable, compare-and-swap row rewriter | accepted (2026-08-27, with amendments) |
| [0003](0003-blind-index.md) | keyed blind indexes, per-tenant by default, equality only | accepted (2026-08-27, with one amendment) |
| [0004](0004-migration-from-cloak.md) | Migration from a prior encryption scheme, with cloak_ecto as the named case | accepted (2026-08-27) |

New ADRs: next number, same three-section format (Context, Decision,
Consequences), plus the typespecs and worked-example sections this family's
records carry. Pick the number against a freshly fetched remote.

This repository inherits the family's ADR practice rather than restating it,
so there is no local "record architecture decisions" record. A bare
`ADR-NNNN` cites this repository's own records; a cross-repo citation carries
the owning repo's beads prefix (`enc-ADR-0001` is encryptor's ADR-0001,
`st-ADR-0052` is statifier-ex's). Records in sibling repos that are still
being drafted are cited by bead id until their number is assigned.
