# Architecture Decision Records

| # | Decision | Status |
|---|---|---|
| [0001](0001-vault-backed-ecto-types.md) | cloak_ecto-shaped vault-backed types, with tenant context from an explicit process scope | accepted (2026-08-27, with amendments) |
| [0002](0002-migrator.md) | The migrator: a plan-driven, resumable, compare-and-swap row rewriter | accepted (2026-08-27, with amendments) |
| [0003](0003-blind-index.md) | keyed blind indexes, per-tenant by default, equality only | accepted (2026-08-27, with amendments) |
| [0004](0004-migration-from-cloak.md) | Migration from a prior encryption scheme, with cloak_ecto as the named case | accepted (2026-08-27, with amendments) |
| [0005](0005-wrapped-key-row-shape.md) | A wrapped-key row declares its wrapping shape, in a column of its own | accepted (2026-09-13) |
| [0006](0006-scope-names-the-keys-owner.md) | Scope names the key's owner here too, and the key store's column keeps its name | proposed (2026-09-24) |
| [0007](0007-suspension-store-and-shred.md) | A Repo-backed suspension store, and a shred on the key store that returns what it destroyed | proposed (2026-09-24) |

Every amendment section in these four records - the 2026-08-27 and
2026-08-28 sets, and ADR-0003's Amendment C of 2026-09-12 - was accepted by
the operator's reading of 2026-09-13. Each amendment says what it changes; the
decision text above it is unchanged.

New ADRs: next number, same three-section format (Context, Decision,
Consequences), plus the typespecs and worked-example sections this family's
records carry. Pick the number against a freshly fetched remote.

This repository inherits the family's ADR practice rather than restating it,
so there is no local "record architecture decisions" record. A bare
`ADR-NNNN` cites this repository's own records; a cross-repo citation carries
the owning repo's beads prefix (`enc-ADR-0001` is encryptor's ADR-0001,
`st-ADR-0052` is statifier-ex's). Records in sibling repos that are still
being drafted are cited by bead id until their number is assigned.
