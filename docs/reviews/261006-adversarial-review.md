# Adversarial review ledger, 2026-10-06

This ledger lists, by number, what an adversarial reading of this package found
and what was done about each finding. It is a dated record. It is not a page to
learn from, and it is not a decision record.
[The threat model](../explanation/threat-model.md) states the claims these
findings were tested against.

**Self-reviewed, no formal third-party audit.** Two reviewers read the code.
The first is an LLM adversarial pass with fresh context, described below. The
second is the maintainer, who is the team's security lead. Nobody outside the
project reviewed it. This is not an independent engineer's review, and nothing
here says the package is audited, certified or verified secure.

The cryptography below the Ecto types is the vault's, and so is its review:
encryptor keeps a ledger of the same shape for the vault, the message format
and the engine underneath. This ledger covers only what this package adds
above them.

## Scope and method

The LLM pass read encryptor_ecto at commit
[`29a70ad`](https://github.com/riddler/encryptor_ecto/tree/29a70ad8400887aa36dd65bb54fcecb639fb08a9),
the commit that added the threat model. Two more findings, F12 and F13, are
disclosures the threat model makes about itself, entered here so that each has
a disposition; they are read at
[`3711d98`](https://github.com/riddler/encryptor_ecto/tree/3711d986c07bb607e38403b5bc58a80b27441402).
A `file:line` is at that entry's commit, so the line numbers may have moved on
`main` since.

Each entry carries:

- an id, F1 onward;
- where: the file and lines at the named commit, and the function;
- who found it: the LLM pass, the maintainer, or the page that states it;
- a severity on the scale below;
- the claim it breaks, quoted from a public page, a moduledoc, a decision
  record or a code comment;
- a disposition, which is one of:
  - **FIXED** in a named pull request, with the test that pins the fix and
    that test's sabotage note (the mutation that turns it red);
  - **ACCEPTED**, with the maintainer's reason;
  - **DEFERRED** to a named bead in this repository's tracker;
  - **FIX IN PROGRESS** in a named pull request that is not merged yet;
  - **PENDING** the maintainer's disposition.

### The severity scale

- **Critical**: plaintext or key disclosure, or an authentication bypass.
- **High**: a guarantee the documentation states does not hold.
- **Medium**: a weakness that matters only with an unusual configuration or a
  second failure, or a documented guarantee that holds only partly.
- **Low/Info**: hardening, clarity, or a missing test for a claim that does
  hold.

### What a finding holds

A Critical or High finding must be FIXED, or carry the maintainer's ACCEPTED
disposition, before any release prep merges. A Medium or lower finding may ship
DEFERRED to a named bead.

## The LLM pass

One LLM reviewer ran the pass, with no context from the work that wrote the
code or the threat model. The model was `claude-opus-5-5`, and the pass ran on
2026-10-06. Its prompt is kept verbatim in the project's private working
records. In substance it said this:

- **Scope.** encryptor_ecto at a fixed commit of `main` (`29a70ad`). The
  inputs were the threat model, every file under `lib/`, and the accepted
  decision records the code or the threat model cites. The tests were read
  only to check whether a claim is pinned. The engine, at the version
  `mix.lock` resolves, was read only where a claim depends on it. The
  cryptography below the Ecto types was out of scope, as reviewed separately
  in encryptor; the pass attacked what this package adds: the Ecto types
  (cast, dump, load, equality, `nil` and empty handling), the blind indexes
  (what a dump, a dump plus one scope's index key, and a dump kept after a
  shred reveal), the key store (its schema, its columns and what each exposes,
  the Cloud KMS `key_id` derivation), the migrator (its plaintext window, crash
  and resume behaviour, the compare-and-swap), and the suspension rows.
- **Method.** For each claim in the threat model and each security-relevant
  function in `lib/`, try to break it. The prompt named these attacks: wrong or
  missing context; one record's ciphertext substituted for another's; cold,
  warm and poisoned cache states; rotation and shred edge cases; malformed or
  truncated ciphertext; secrets leaking through error messages, logs, telemetry
  or exceptions; timing; configuration a host can get wrong without being
  refused; concurrency; and anything the documentation promises that the code
  does not enforce. A concrete reproduction was preferred to an argument, and
  the reviewer said which findings it reproduced.
- **Severity.** The scale above, in those words.
- **Rules.** Read-only. Every file the reviewer wrote was scratch and was
  deleted before it returned, its scratch test database included. A test run
  held a machine slot. No secret value was read, printed or passed.
- **Return.** The commit reviewed, and for each finding: its severity, where it
  is, the claim it breaks, whether it was reproduced or reasoned, and a
  suggested disposition. Then the claims it attacked and could not break.

The prompt named a security model page beside the threat model; this package
has none at `29a70ad`, so the pass took its claims from the threat model, the
moduledocs, the guides and the decision records.

Its findings are F1 to F11 below.

These are the claims it attacked and could not break, at `29a70ad`. One line
each, as it reported them:

- A value moved to another column or another scope's row fails to decrypt
  (outside the legacy window), and the two cases raise different exceptions.
- A missing scope raises on dump and load; the legacy fallback never answers a
  missing scope or context key.
- `scope: :none` against a `:scoped`-profile vault raises `VaultProfileError`;
  the resolver's `:none` arm is refused.
- Exception messages and `inspect` carry no plaintext or ciphertext bytes
  (`redact/1` holds; raised legacy, serializer, validator and normalizer
  errors are reduced to module names).
- `nil` passes through unencrypted, `""` is encrypted, and a `nil` source
  writes a `nil` index.
- Blind index: the info string binds table, column, index name and version
  (the separator is refused); per-scope indexes need a scope and raise at
  query build; `slow: true` without `:slow_hash` is refused; a truncated index
  is refused by `where_eq`; `scope: :none` fields must declare `:global`; an
  index column cannot itself be encrypted.
- Key store: rows are found by the keyed `scope_ref`, never the selector; the
  wrapping is bound to `scope_ref`, version and namespace (moved or relabelled
  rows do not unwrap); an unknown wrapping shape or a wrong `key_id` fails
  closed; an empty selector gets `unknown_key`; the table name is
  grammar-checked.
- Shred: one transaction under `FOR UPDATE` with a re-check for late versions;
  the current version cannot be shredded alone; telemetry metadata is limited
  to vault, procedure and table; the drain wait is the cache's `max_age`.
- Migrator: one transaction per batch with the checkpoint inside it, and a
  halt rolls both back; a dry run and a verification write no checkpoint; a
  write is refused for `source_authenticated: false` without `validate:`; a
  `from:` of this package's own type with `legacy:` must declare
  authentication; the target's `legacy:` is dropped for probes; a `NULL`
  scope column is an error, never `:none`; the per-row scope key is restored
  in an `after`; the failure list is bounded at 100.
- `Declarations.check_unique!/1` flags two physical columns that share a
  declared pair.

## The maintainer's review

The maintainer reviews the threat model and this ledger himself. His findings
are entered here verbatim, attributed "the maintainer", each with its own
F-entry, when he reviews the pull request that adds this ledger. That pull
request merges only after his approving review.

No entries yet.

## The findings

| Id | Severity | Found by | Disposition |
|---|---|---|---|
| F1 | High | the LLM pass | FIXED, PR 150 |
| F2 | High | the LLM pass | FIXED, PR 151 |
| F3 | Medium | the LLM pass | FIXED, PR 148 |
| F4 | Medium | the LLM pass | FIXED, PR 147 |
| F5 | Low | the LLM pass | DEFERRED to ece-q6tp |
| F6 | Low | the LLM pass | DEFERRED to ece-q6tp |
| F7 | Low | the LLM pass | DEFERRED to ece-q6tp |
| F8 | Low/Info | the LLM pass | DEFERRED to ece-hr4e |
| F9 | Low/Info | the LLM pass | DEFERRED to ece-q6tp |
| F10 | Low/Info | the LLM pass | DEFERRED to ece-q6tp |
| F11 | Low/Info | the LLM pass | DEFERRED to ece-hr4e |
| F12 | Low/Info | the threat model | PENDING the maintainer's disposition |
| F13 | Low/Info | the threat model | PENDING the maintainer's disposition |

Under the rule above, no finding here keeps a release prep from merging: the
two High findings, F1 and F2, are FIXED.

### F1. While `legacy:` is set, a migrated row can be overwritten with legacy bytes that load

- **Where:** `lib/encryptor/ecto/binary.ex:716-737` at `29a70ad`
  (`legacy_arm_or_raise!/4`, which calls `legacy_load/2`). While a field
  declares `legacy:`, any refusal of the stored bytes by the vault falls
  through to the legacy reader.
- **Found by:** the LLM pass. Reproduced: under one scope, another scope's
  bytes in this package's format raise `DecryptError`, but that other scope's
  legacy-format bytes written into the same row load. A cloak-format value
  carries no context, so a database writer can put a legacy value from another
  row, scope or column, or from an old backup, over a row that was already
  migrated, and the row loads. The reproduction used the test suite's
  stand-in for the legacy format, so it shows the code path rather than
  cloak itself.
- **Severity:** High.
- **Claim broken:** `docs/explanation/moving-off-cloak.md:219-224`, "The
  window does not weaken any *migrated* row. It means the guarantee is per-row
  until the pass finishes - and because there is no legacy dump arm, no new
  legacy-format row can appear behind it, so the pass finishing is what
  restores the property. Dropping `legacy:` afterwards is hygiene rather than
  the thing that fixes it". The `Encryptor.Ecto.Binary` moduledoc says the
  same (`lib/encryptor/ecto/binary.ex:241-243`, "No *migrated* row is
  weakened").
- **Disposition:** FIXED in
  [PR 150](https://github.com/riddler/encryptor_ecto/pull/150), by
  documentation, as the maintainer disposed it on 2026-10-07: fix the
  documentation, with a test pinning the documented behaviour. The
  `Encryptor.Ecto.Binary` moduledoc, the explanation's section now titled "The
  mixed window is a downgrade until `legacy:` is dropped", the runbook and the
  threat model say that dropping `legacy:` is what closes the window, and that
  a `[:encryptor_ecto, :legacy_load]` event for a column a full verification
  already found clean reveals such a load. Two tests in "legacy-format bytes
  put into a migrated row"
  ([`test/encryptor/ecto/legacy_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/legacy_test.exs))
  pin it:
  - "load while legacy: is declared, and are counted as a legacy read". Its
    sabotage note: replacing the body of `emit_legacy_load/1` with `:ok` turns
    it red.
  - "raise once legacy: is dropped, while the migrated row still loads". Its
    sabotage note: letting the `%{legacy: nil}` clause of
    `legacy_arm_or_raise!/4` fall through to a legacy reader turns it red.

  The same sentence stands in decision 5 of
  [ADR-0004](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0004-migration-from-cloak.md);
  a Note on it is DEFERRED to ece-wncp.

### F2. Two rows in the same column and scope can swap ciphertexts

- **Where:** `lib/encryptor/ecto/binary.ex:689-691` at `29a70ad`
  (`declared_context/1`): the context a field writes is its table, its column,
  the scope reference on a scoped field and any static pairs. Nothing in it is
  per row.
- **Found by:** the LLM pass. Reproduced: one row's bytes, written into another
  row of the same column and scope, load as the first row's value.
- **Severity:** High. The threat model itself states the binding correctly, as
  column and scope only; the three pages below claim more.
- **Claims broken:** the `Encryptor.Ecto.DecryptError` moduledoc
  (`lib/encryptor/ecto/decrypt_error.ex:7-11`), "a ciphertext lifted out of
  one row and dropped into another fails authentication rather than decrypting
  into the wrong place". The context section of
  [ADR-0001](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0001-vault-backed-ecto-types.md)
  uses the same words. `docs/guides/bind-extra-context.md:5-8` says the
  context "is what makes a row's ciphertext non-substitutable", "whatever else
  an attacker with database access can rearrange", while the same guide
  advises against per-row values in a declared context.
- **Disposition:** FIXED in
  [PR 151](https://github.com/riddler/encryptor_ecto/pull/151), by
  documentation, as the maintainer disposed it on 2026-10-07: fix the
  documentation, with a test pinning the documented behaviour. The
  `Encryptor.Ecto.DecryptError` moduledoc, the guide, the `Encryptor.Ecto.Binary`
  moduledoc, the explanation and the threat model say that the context binds a
  column and a scope, not a row, and that bytes swapped between two rows of one
  column and scope both load. ADR-0001 carries a dated foot Note (2026-10-07)
  that narrows its Context sentence the same way and leaves the sentence as
  written. One test in "two rows of one column and scope with their bytes
  swapped"
  ([`test/encryptor/ecto/binary_repo_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/binary_repo_test.exs))
  pins it: "both load, each as the other's value". Its sabotage note: making
  `declared_context/1` add a pair that differs on every call turns it red. That
  mutation also turns the existing round-trip test red, so it shows the test
  asserts loads rather than refusals; no mutation can bind a row the field's
  parameters do not know.

### F3. A host reader's or writer's error reason reaches the report and the CLI unreduced

- **Where:** at `29a70ad`,
  `lib/encryptor/ecto/migrator/source/ecto_type.ex:92` (`normalize/1`) and
  `lib/encryptor/ecto/migrator/source.ex:215-221` (`load/3`) pass an
  `{:error, reason}` from the host's module through unchanged;
  `lib/encryptor/ecto/migrator/pass.ex:821-822` (`write_target/2`) does the
  same for a `to:` that returns one. The reason reaches `Report.failures` and
  the `:progress` callback, and `lib/encryptor/ecto/migrator/cli.ex:445-449`
  (`failure_lines/1`) prints it with `inspect/1`. Only a raise is reduced to
  its module.
- **Found by:** the LLM pass. Reproduced: a `from:` reader returning an error
  tuple that carried the value it was holding put that value into
  `report.failures`, and the CLI line printed it.
- **Severity:** Medium. It needs a host reader that puts a value into its own
  error term.
- **Claims broken:** the threat model's "The migrator's plaintext window": "a
  failure carries the primary key, the schema, the field, and a reason reduced
  to atoms and module names". The `Encryptor.Ecto.Migrator.Report` moduledoc
  says failure reasons are "reduced to module names and atoms".
- **Disposition:** FIXED in
  [PR 148](https://github.com/riddler/encryptor_ecto/pull/148). Every error
  reason a host module returns is reduced to its shape before it reaches the
  report, the `:progress` callback or the CLI, and the CLI renders a failure's
  reason by shape whoever recorded it. Four tests pin it:
  - in "a reason a host module returns"
    ([`test/encryptor/ecto/migrator_run_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/migrator_run_test.exs)),
    "from a reader, reaches the report and the progress callback as its
    shape", "from a writer, keeps its atoms and drops every other term" and
    "from a reader in a verification, is reduced the same way". Their
    sabotage note: making `fail/4` record the reason as the host returned it
    turns each one red.
  - "a failure line renders a reason by shape, whoever recorded it"
    ([`test/encryptor/ecto/migrator/cli_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/migrator/cli_test.exs)).
    Its sabotage note: rendering the reason with `inspect/1` rather than
    `Encryptor.Ecto.Error.redact/1` turns it red.

### F4. A resume reused a checkpoint written under different filters

- **Where:** at `29a70ad`, `lib/encryptor/ecto/migrator/pass.ex:391-396`
  (`resume_cursor/2`, `checkpoint_key/1`) and
  `lib/encryptor/ecto/migrator/checkpoint.ex:116,140` (`fetch_cursor/4`,
  `record/5`). The checkpoint key was plan, schema, field and prefix. It
  ignored `only_scopes:`, `except_scopes:` and `writing_key:`, and a finished
  pass never cleared it. A later run with `resume: true` skipped every row
  below the old cursor and exited 0. A rotation run one scope at a time and
  resumed for a second scope left that scope's low rows under the outgoing
  version, which a later single-version shred would make undecryptable.
- **Found by:** the LLM pass. Reproduced: a write with `only_scopes:` naming one
  scope, then `resume: true` for another, reported all-zero counts and `ok?`
  true, and the second scope's row was still in the old format.
- **Severity:** Medium.
- **Claims broken:** the `Encryptor.Ecto.Migrator` moduledoc
  (`lib/encryptor/ecto/migrator.ex:36-38`), "the checkpoint is a performance
  record rather than a correctness one". The threat model's "a re-run
  converges on the same end state".
- **Disposition:** FIXED in
  [PR 147](https://github.com/riddler/encryptor_ecto/pull/147). The
  checkpoint now records the run (the scope filters and the writing key), a
  resume under a different run is refused with an `ArgumentError` naming each
  option that differs, before any row is visited, and a pass that reaches the
  end of its rows is marked complete. The tests in "a resume continues only
  the run that recorded the checkpoint"
  ([`test/encryptor/ecto/migrator_run_test.exs`](https://github.com/riddler/encryptor_ecto/blob/main/test/encryptor/ecto/migrator_run_test.exs))
  pin it:
  - "a resume under other scope filters is refused before a row is visited".
    Its sabotage note: making `Checkpoint.fetch/4` skip the run comparison
    turns it red, with the resume returning every count at zero and the row
    untouched.
  - "a resume under another writing key is refused". Its sabotage note:
    dropping `writing_key` from `Checkpoint.run/3` turns it red.
  - "a resume of a completed pass is a no-op that says so". Its sabotage note:
    making `record/6` write `"complete"` as `false` on every call turns it red.

### F5. The blind index's HMAC is computed in this package

- **Where:** `lib/encryptor/ecto/blind_index/value.ex:180-191` at `29a70ad`
  (`compute!/4`). The index value is `:crypto.mac/4` called here, over a raw
  index key the vault's derivation hands to this package's process.
- **Found by:** the LLM pass. Reasoned.
- **Severity:** Low. The construction is pinned by golden vectors; the
  sentence below is what is inexact.
- **Claim:** the threat model's "What was tested, and how": "This package
  performs no cryptography of its own: encryption, decryption, the index key
  derivation and the Argon2id slow hash are all calls into the vault."
- **Disposition:** DEFERRED to ece-q6tp, which corrects the sentence.

### F6. A scalar type's ciphertext length tells a number's magnitude

- **Where:** `lib/encryptor/ecto/scalar.ex:147-151` at `29a70ad`
  (`to_plaintext/2`). Integers and floats are encrypted as their decimal text.
- **Found by:** the LLM pass. Reproduced: 1-, 5- and 10-digit integers
  encrypted to 313, 317 and 322 bytes.
- **Severity:** Low. The threat model's claim holds: a dump yields "each
  value's length". For these types that length is a magnitude, and nothing at
  the types says so.
- **Claim:** the threat model's "What a dump reveals".
- **Disposition:** DEFERRED to ece-q6tp, which states it in the threat model
  and at the scalar types.

### F7. A database writer can lift or impose a suspension

- **Where:** `lib/encryptor/ecto/suspension_store.ex:145-185` at `29a70ad`
  (`suspend/2`, `reinstate/2`, `list/1`). Deleting a row reinstates that scope
  on every node at the next poll; inserting one suspends a scope.
- **Found by:** the LLM pass. Reasoned.
- **Severity:** Low.
- **Claim:** none broken. The threat model covers what a dump of this table
  reveals, not its integrity.
- **Disposition:** DEFERRED to ece-q6tp, which adds the integrity line to the
  threat model.

### F8. The table-name grammar accepts a trailing newline

- **Where:** `lib/encryptor/ecto/key_store.ex:341` and
  `lib/encryptor/ecto/suspension_store.ex:103` at `29a70ad`, the
  `@table_name ~r/^[a-z_][a-z0-9_]*$/` check. `$` matches before a trailing
  newline.
- **Found by:** the LLM pass. Reproduced: a table name ending in a newline
  passes `init/2`. Not exploitable: the adapter quotes table names.
- **Severity:** Low/Info.
- **Claim:** the stores' comments, which say the table-name grammar is checked
  there.
- **Disposition:** DEFERRED to ece-hr4e, which anchors the grammar with `\A`
  and `\z`.

### F9. Exception messages carry the raw scope selector

- **Where:** `lib/encryptor/ecto/error.ex:172-181` at `29a70ad`
  (`common_detail/1`). Every exception message and `inspect/2` result of this
  package's errors shows the scope selector, so logs can carry what the key
  store keeps out of its columns.
- **Found by:** the LLM pass. Reasoned. The selector in the error is
  documented: ADR-0001 decision 6 lets every exception carry the context
  keys "not values beyond the tenant identifier".
- **Severity:** Low/Info.
- **Claim:** none broken. The threat model's key-store section says "a
  selector in a column would publish the host's scope identifiers", and does
  not say where else the selector appears.
- **Disposition:** DEFERRED to ece-q6tp, which states it in the threat model.

### F10. The compare-and-swap compares only the target column

- **Where:** `lib/encryptor/ecto/migrator/pass.ex:846` at `29a70ad` (`swap/5`)
  and `lib/encryptor/ecto/migrator/keyset.ex:140-141` (`swap_query/5`).
- **Found by:** the LLM pass. Reasoned: with different source and target
  columns, a row the application rewrote mid-pass is detected only if the
  application also writes the target column. The migrate-from-cloak guide says
  so; the threat model does not.
- **Severity:** Low/Info.
- **Claim:** the threat model's "the compare-and-swap means a row the
  application rewrote in the meantime is counted rather than overwritten".
- **Disposition:** DEFERRED to ece-q6tp, which adds the condition to that
  sentence.

### F11. A comment names only `Binary` as defining the declaration marker

- **Where:** `lib/encryptor/ecto/migrator.ex:690-693` at `29a70ad`, the
  comment above `@our_params`. It says only `Encryptor.Ecto.Binary` defines
  `__encryptor_ecto__/1`; the `String` and `Map` types and the scalar types
  define it too.
- **Found by:** the LLM pass. A stale comment with no security effect.
- **Severity:** Low/Info.
- **Claim:** the comment itself.
- **Disposition:** DEFERRED to ece-hr4e, which corrects the comment.

### F12. A Cloud KMS row's `key_id` confirms a guessable selector

- **Where:** `docs/explanation/threat-model.md:236-246` at `3711d98`, "The key
  store's columns, and what each exposes". The `CryptoKey` id is an unkeyed
  SHA-256 digest of the namespace and the selector, and the namespace is in
  the same row, so a reader of a dump who can enumerate candidate selectors
  can confirm which one a Cloud KMS row belongs to.
- **Found by:** the threat model, which states it. The page records the unkeyed
  digest as deliberate, with its reason: a Cloud KMS key cannot be renamed or
  deleted, and a keyed id would rename every scope's key on a root rotation
  (encryptor's `Encryptor.Provider.GcpKms`, "The `CryptoKey` id").
- **Severity:** Low/Info. The page tells a host with guessable selectors and
  Cloud KMS scope keys to treat the scope list as visible to a dump.
- **Claim:** none broken; the page discloses it.
- **Disposition:** PENDING the maintainer's disposition.

### F13. A suspension row outlives a shred

- **Where:** `docs/explanation/threat-model.md:179-181` at `3711d98`, "What a
  dump retained after a shred reveals". A scope suspended before it was
  shredded, and never reinstated, keeps its suspension row, and that row holds
  the selector in the clear. The shred's delete is scoped to the key store's
  table.
- **Found by:** the threat model, which states it.
- **Severity:** Low/Info.
- **Claim:** none broken; the page discloses it.
- **Disposition:** PENDING the maintainer's disposition.
