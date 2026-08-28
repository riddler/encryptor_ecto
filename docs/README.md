# Documentation

The pages here are organized by what a reader needs from them, in the
[Diataxis](https://diataxis.fr) sense: a page either helps you *do* something or
helps you *understand* something, and mixing the two makes it worse at both. A
page that starts explaining in the middle of a runbook, or starts instructing in
the middle of an explanation, is a defect here rather than a stylistic
preference.

## Explanation

Read at leisure, away from a terminal.

- [What changes when you move off cloak_ecto](explanation/moving-off-cloak.md) -
  what a migration onto this package changes *semantically*: per-tenant keys
  where cloak had one key, the encryption context and the substitution it
  forbids, fail-closed tenant scope and the boundary audit that is the real cost
  of adoption, crypto-shredding and the field that opts out, why encrypted
  columns are not queryable, what a keyed blind index restores and what it does
  not, and why the mixed window is a per-row downgrade while it is open.

## How-to guides

Task-shaped, for someone who already understands the target state. **Not written
yet.** The migration runbook (`guides/migrate-from-cloak.md`) is fixed as
ADR-0004 decision 8 and is the next page due.

## Reference

No page here. The mix tasks' flag tables, exit codes and grammar are their own
`@moduledoc`s, rendered by ExDoc, so that they live with the code that parses
them and the two cannot drift (ADR-0004 decision 10). The tasks are not
implemented yet; until they are, their grammar is ADR-0004 decision 6.

## Tutorial

**There is deliberately no tutorial, and this is the note saying so** - so that
nobody writes one on the reasonable observation that the set has a hole in it.

A tutorial's promise is a safe place to practice. For a destructive migration
performed on live production data, a practice article would either operate on a
host's real data, which is the thing it is supposed to teach them to be careful
with, or on a toy that omits every property making the real one hard: live
traffic, tenant scope, rows that will not decrypt. The dry run is the rehearsal.
It runs against the host's own data, it is a step of the how-to guide, and a
fake one alongside it would compete with it (ADR-0004 decision 10).

## Records

- [Architecture decision records](adr/README.md) - the contracts every page
  above renders.
- `plans/` - implementation plans derived from those records. Working documents,
  not user documentation.
