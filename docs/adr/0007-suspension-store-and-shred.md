# ADR-0007: A Repo-backed suspension store, and a shred on the key store that returns what it destroyed

Status: accepted (2026-09-24)

## Context

Two records in `encryptor` leave a piece of work to the package that owns the
key store's table, and this package is that one.

enc-ADR-0010 makes a vault's suspended set something read through a
behaviour, `Encryptor.Vault.Suspension.Store`, with four callbacks (`init/2`,
`suspend/2`, `reinstate/2`, `list/1`). Its default store is the per-node table
enc-ADR-0005 Amendment A fixed, and its decision 10 says the shared store is
the host's: "A Repo-backed store is planned for `encryptor_ecto`, as a later
piece of work in that repository; it is not landed, and this record does not
decide its schema." The behaviour, the refresher that reads a shared store
into each node's view, and the failure mode when the store is unreachable
(its decision 7) are all in `encryptor` 0.5.0
(`Encryptor.Vault.Suspension.Store`, `Encryptor.Vault.Suspension.refresh/2`).
What is left is a store, and its schema.

enc-ADR-0005 decision 1's table gives crypto-shred's function owner as
`encryptor` and its walk owner as "the key store's package". Its P3 (a whole
scope) and P4 (one version) are procedures, not functions: decision 10 ships
no shred function in `encryptor` because "deleting a wrapping is a `DELETE`
against the host's store". This package's `Encryptor.Ecto.KeyStore` is that
store (enc-ADR-0002 decision 5 put the Ecto-backed provider here, and ADR-0005
here fixed its row shape), so the `DELETE` is a query against a table this
package already reads. Today a host writes it by hand, as the Google Cloud
KMS guide's shred step does.

This package's ADR-0002 decision 9, accepted before the key store moved here,
says "No re-wrap, no key creation, no shred (R1 and R4 above). Those touch the
key store, which is `encryptor`'s". The key store is no longer `encryptor`'s,
and the seam that decision gives - "if an operation would still be needed by a
host that stores its ciphertext somewhere other than Ecto, it is not this
package's" - reads the other way for a delete against an Ecto table: a host
whose keys are not in this table has no use for it.

One fact about the running code shapes the drain. enc-ADR-0005's P3 step 3
says that until the caches drain "a running node can still decrypt the
tenant's data from cached materials". In `encryptor` 0.5.0 every encrypt and
decrypt asks the provider before it builds the caching materials manager
(`Encryptor.Vault.Resolve.decryption_keys/3` and the order in
`Encryptor.Vault.Decrypt`'s module comment, step 3 before step 7), so after
P3 the provider's `{:unknown_key, selector}` is the answer at once, warm cache
or not. P4 is different: the scope still resolves to its remaining versions,
and a cached decryption entry for a value written under the retired version is
keyed by the message's own encrypted data keys and context, so it serves until
`max_age` passes. The tests in `test/encryptor/ecto/key_store_shred_repo_test.exs`
("the drain") pin both halves.

`encryptor` cites in this record were read at `be0036b` (`v0.5.0` is its
parent `9ad74e2`, and the two agree on every file cited); this package's at
the commit that adds this record.

## Decision

**1. `Encryptor.Ecto.SuspensionStore` is the Repo-backed store.** It
implements `Encryptor.Vault.Suspension.Store` over one table:

| Column | |
|---|---|
| `id` | the default surrogate key; never selected |
| `vault` | the vault module the set belongs to, as `inspect/1` spells it |
| `selector` | the suspended scope's selector, as the host passed it to `Encryptor.Vault.suspend/2` |
| `inserted_at` | when the suspension was first written, UTC; written, never read |

with one unique index over `{vault, selector}`. The index is what makes
`suspend/2` idempotent at the database (`ON CONFLICT DO NOTHING`), and the
`vault` column is what keeps two vaults' sets apart in one table, as
enc-ADR-0010 decision 1 requires.

Its options are `:repo` (required), `:table` (default
`"encryptor_suspensions"`) and `:prefix`, checked in `init/2` with no I/O, and
nothing else: any other option is refused, so the poll interval stays the
vault's `:suspension_poll_interval` and cannot be configured twice.

The selector is stored as the host wrote it. The key store keeps only a keyed
reference because its rows sit beside every ciphertext; this table cannot,
because `list/1` answers selectors and a keyed reference does not turn back
into one. enc-ADR-0010 decision 8 already sends an operator who needs to know
which scope was suspended to the store.

A selector that is not a non-empty string - `:default` included - is refused
by `suspend/2` as `{:unsupported_selector, selector}`, which the vault reports
as a failed write. A string column cannot hold `:default` apart from a scope
named `"default"`, and a scoped vault has no `:default` scope. `reinstate/2`
answers `:ok` for such a selector, since it can never be in the set.

A database failure is not translated. The vault already treats a callback's
`{:error, term}`, exit and raise as one outcome and keeps the exception in the
error's `:engine` field (enc-ADR-0010 decision 7, `Encryptor.Vault.Suspension`'s
`call_store/3`), so the store lets the exception raise.

**2. The table ships as a generator, as the key store's does.**
`mix encryptor.ecto.gen.suspension_store_migration [--table NAME]
[--migrations-path PATH]` writes the migration into the host's tree through the
same `Encryptor.Ecto.Migrator.CLI.gen/2` the key-store generators use, with
their refusals. This package still issues no DDL (ADR-0002 decision 9).

**3. `Encryptor.Ecto.KeyStore.shred/3` performs enc-ADR-0005's P3 and P4
against the store a running vault reads.**

    shred(vault, selector, version: :all | pos_integer(), drain: :wait | :skip)

- `vault` is a started vault whose provider is `Encryptor.Ecto.KeyStore`. The
  repo, table, prefix and reference subkey come from the provider state that
  vault froze at start, so the shred cannot reach a different store from the
  one the vault decrypts through. Any other vault is refused as
  `{:not_a_key_store_vault, vault}`.
- `version: :all` is P3's step 2; `version: n` is P4's step 1. `:version` is
  required: an irreversible call does not get a default.
- The scope's rows are read `FOR UPDATE` and deleted in one transaction, so
  the versions the record names are the versions deleted, and the partly
  completed P3 step 2 that enc-ADR-0005 calls its worst state cannot happen
  through this call.
- P4 refuses the scope's newest version as `{:current_version, n}`. Removing
  it would make an older version current again, and a scope whose only
  version goes is P3, whose preconditions ask for a decision of its own.
- `drain: :wait`, the default, is P3's step 3 and P4's step 2: the call
  returns once the vault's cache `max_age` has passed after the delete
  committed, and at once for a vault configured `cache: false`. `drain: :skip`
  returns at once, for a host that restarts its vaults instead. The wait is
  kept for P3 although `encryptor` 0.5.0 answers `{:unknown_key, selector}`
  at once (Context): enc-ADR-0005 makes the drain a step of both procedures,
  and a later `encryptor` that served cached materials ahead of the provider
  would make it load-bearing again without this package changing.
- Every refusal deletes nothing: `{:unknown_key, selector}` for a scope with no
  rows or no scope reference, `{:unknown_version, n}`, `{:current_version, n}`,
  `{:key_unavailable, selector}` for the transient store failures the
  provider callbacks answer that for, the vault's own error when it is not
  started, and the option refusals.

The procedures' preconditions stay the operator's: the recorded human
decision P3 requires, and the green whole-scope verification P4 requires.
`shred/3` is never called from a provider callback and never on a schedule;
it is the one write the key store performs.

**4. The record is `%Encryptor.Ecto.KeyStore.Shred{}`.** P3 step 1 asks the
operator to record "the count and the version numbers in the change record";
the struct is that record, returned by the call that performed the delete:

| Field | |
|---|---|
| `vault` | the vault whose store was shredded |
| `procedure` | `:scope` (P3) or `:version` (P4) |
| `scope_ref` | the scope reference, the value in the table's `tenant_ref` column |
| `versions` | the versions deleted, ascending |
| `remaining` | the versions still live, ascending; `[]` after P3 |
| `table`, `prefix` | where the rows were deleted from |
| `deleted_at` | when the delete committed, UTC |
| `drained_at` | `deleted_at` plus the vault's cache `max_age`, or `deleted_at` under `cache: false` |
| `drain` | `:waited` or `:skipped` |

The selector is not a field: a change record outlives the scope, and the
scope reference identifies its rows without publishing the host's identifier.
`drained_at` holds for every node when every node runs the vault with the same
`max_age`, which one vault module's configuration gives.

**5. `[:encryptor_ecto, :shred]` is the one new telemetry event.** A point
event, one per successful shred, emitted after the delete commits and before
the drain wait. Its measurement is `count`, the number of versions deleted.
Its metadata is closed at `vault`, `procedure` and `table`: no selector, no
scope reference and no version number, because enc-ADR-0006 decision 6 puts
no per-scope dimension on any event and a shred is the event an operator would
most want to label with its scope. A refusal emits nothing. The suspension
store adds no event of its own: every write and refresh through it is already
`[:encryptor, :suspension, :changed]` (enc-ADR-0010 decision 8).

**6. What this record amends.** If this record is accepted, ADR-0002
decision 9's second bullet reads with one qualification: re-wrap and key
creation stay out of this package, and so does any shred as a `mix` task, but
`Encryptor.Ecto.KeyStore.shred/3` deletes from the key store this package owns,
as enc-ADR-0005 decision 1's table assigns the walk to the key store's package.
The README's "no shred verb" sentence changes with the code. The decision text
of ADR-0002 is unchanged.

## Consequences

- **A shared suspension needs one migration and one line of vault
  configuration.** The host runs the generated migration and sets
  `suspension_store: {Encryptor.Ecto.SuspensionStore, repo: MyApp.Repo}`;
  everything else is `encryptor`'s refresher.
- **Renaming a vault module starts it with an empty set.** The `vault` column
  keys the rows by the module's name, so a rename carries its rows across in
  the same deploy or loses its suspensions. Before its first read the renamed
  vault denies every scope (enc-ADR-0010 decision 7), and after it, it serves
  them.
- **A scope a host suspends is written down in plaintext in the host's
  database.** That is what makes it listable, and it is the host's own table.
- **A shred is now one call instead of hand-written SQL,** and it cannot
  delete from a table the vault does not read, leave a partly completed P3,
  or retire the version writes go under.
- **`drain: :wait` blocks for `max_age`.** It is an operator verb run from a
  console or a release task, so the wait is the procedure doing what it says;
  a host that cannot hold a console for `max_age` restarts its vaults and
  passes `drain: :skip`.

## The contract as typespecs

```elixir
defmodule Encryptor.Ecto.SuspensionStore do
  @behaviour Encryptor.Vault.Suspension.Store

  @type state :: %{repo: module(), vault: String.t(), table: String.t(), prefix: String.t() | nil}

  @spec default_table() :: String.t()
  @spec init(module(), keyword()) :: {:ok, state()} | {:error, term()}
  @spec suspend(state(), Encryptor.Error.selector()) :: :ok | {:error, term()}
  @spec reinstate(state(), Encryptor.Error.selector()) :: :ok | {:error, term()}
  @spec list(state()) :: {:ok, [String.t()]} | {:error, term()}
end

defmodule Encryptor.Ecto.KeyStore do
  @spec shred(module(), Encryptor.Provider.selector(), keyword()) ::
          {:ok, Encryptor.Ecto.KeyStore.Shred.t()} | {:error, shred_error()}
end

defmodule Encryptor.Ecto.KeyStore.Shred do
  @type t :: %__MODULE__{
          vault: module(),
          procedure: :scope | :version,
          scope_ref: String.t(),
          versions: [pos_integer(), ...],
          remaining: [pos_integer()],
          table: String.t(),
          prefix: String.t() | nil,
          deleted_at: DateTime.t(),
          drained_at: DateTime.t(),
          drain: :waited | :skipped
        }
end
```

## Worked example

A host runs its scoped vault with both pieces:

```elixir
config :my_app, MyApp.ScopedVault,
  suspension_store: {Encryptor.Ecto.SuspensionStore, repo: MyApp.Repo},
  suspension_poll_interval: 5_000
```

A customer asks to leave. The operator suspends the scope first, from one
node, and every node refuses it within one poll interval:

```elixir
:ok = Encryptor.Vault.suspend(MyApp.ScopedVault, "workspace-7")
```

When the recorded decision to destroy the data arrives, the operator shreds
the scope and files the record in the change log:

```elixir
{:ok, shred} = Encryptor.Ecto.KeyStore.shred(MyApp.ScopedVault, "workspace-7", version: :all)
#=> %Encryptor.Ecto.KeyStore.Shred{procedure: :scope, versions: [1, 2, 3], remaining: [],
#     deleted_at: ~U[...], drained_at: ~U[...], drain: :waited, ...}

{:error, %Encryptor.Error{reason: {:unknown_key, "workspace-7"}}} =
  MyApp.ScopedVault.decrypt(ciphertext, key: "workspace-7", encryption_context: context)
```

A rotation elsewhere closes its window with P4, after the rewrite pass and a
green verification:

```elixir
{:ok, %Encryptor.Ecto.KeyStore.Shred{procedure: :version, versions: [1], remaining: [2]}} =
  Encryptor.Ecto.KeyStore.shred(MyApp.ScopedVault, "workspace-9", version: 1)
```

## Open questions

1. **Whether P3's drain wait should go.** `encryptor` 0.5.0 answers
   `{:unknown_key, selector}` after P3 without it (Context). Dropping it for
   P3 would make the call match today's engine and depend on its ordering;
   keeping it matches enc-ADR-0005's text. Owner: this repository, after
   `encryptor` says whether P3 step 3's sentence still describes its code.
2. **Whether a single-profile vault earns a shared suspension.** `:default` is
   refused today (decision 1). A host that wants to suspend a whole
   single-profile vault on every node would need the table to tell `:default`
   apart from a string, which is a column this record does not add.
3. **Whether the suspension table should record who suspended a scope, and
   why.** It records when. A reason column is the host's audit trail, not the
   vault's, and nothing here reads it.

## Note (2026-09-24): the operator accepted this record, and with it decision 6's qualification of ADR-0002 decision 9

The Status line at the head of this file now reads `accepted (2026-09-24)`,
and the index row in `docs/adr/README.md` says the same. The store and the
shred shipped in `encryptor_ecto` 0.6.0 on Hex, the commit tagged `v0.6.0`
(`cf4fd54`).

**Accepting this record qualifies an accepted one.** Decision 6 opens "If
this record is accepted"; it now is. ADR-0002 decision 9's second bullet reads
with decision 6's qualification: re-wrap and key creation stay out of this
package, and so does any shred as a `mix` task, but
`Encryptor.Ecto.KeyStore.shred/3` deletes from the key store this package
owns. ADR-0002's text is unchanged, as decision 6 says; this Note is where the
qualification is recorded as accepted. The open questions stay open:
acceptance answers none of them.

Every claim was re-verified immediately before the flip, against this
package's main at `cf4fd54` and against `encryptor` `v0.5.0` (`9ad74e2`), the
release 0.6.0 pins:

- Context. `Encryptor.Vault.Suspension.Store` has the four callbacks, and
  `Encryptor.Vault.Suspension.refresh/2` and its `call_store/3` are in
  `encryptor` 0.5.0; `Encryptor.Vault.Decrypt`'s module comment orders the
  provider's `decryption_keys/2` at step 3 and the CMM stack at step 7; the
  describe block "the drain" is in
  `test/encryptor/ecto/key_store_shred_repo_test.exs`.
- Decision 1. `Encryptor.Ecto.SuspensionStore` implements the behaviour, keys
  its rows by `inspect(vault)` (`init/2`), inserts with `on_conflict:
  :nothing` over `[:vault, :selector]` (`suspend/2`), refuses a selector that
  is not a non-empty string as `{:unsupported_selector, selector}`
  (`suspend/2`), answers `:ok` for one in `reinstate/2`, rescues nothing, and
  refuses unknown options (`known_options/1`), with `"encryptor_suspensions"`
  the default table (`default_table/0`).
- Decision 2. `mix encryptor.ecto.gen.suspension_store_migration` takes
  `--table` and `--migrations-path`, runs through
  `Encryptor.Ecto.Migrator.CLI.gen/2`, and writes the three columns and the
  unique index over `[:vault, :selector]`.
- Decision 3. `Encryptor.Ecto.KeyStore.shred/3` takes the provider state the
  vault froze (`key_store_state/1`, refusing `{:not_a_key_store_vault,
  vault}`), requires `:version` (`shred_version/1`), defaults `:drain` to
  `:wait` (`shred_drain/1`), reads `FOR UPDATE` and deletes in one transaction
  (`delete_versions/4`), refuses `{:unknown_key, selector}`,
  `{:unknown_version, n}` and `{:current_version, n}` (`doomed/3`), and waits
  out `max_age`, or nothing under `cache: false` (`drain_seconds/1`).
- Decision 4. `%Encryptor.Ecto.KeyStore.Shred{}` has the ten fields and
  `drain: :waited | :skipped` (`Encryptor.Ecto.KeyStore.Shred`, `@type t`).
- Decision 5. `[:encryptor_ecto, :shred]` is emitted after the delete and
  before the wait, with `count` and metadata closed at `vault`, `procedure`
  and `table` (`emit_shred/4`).
- Decision 6. The README's "no shred verb" sentence is gone: it names
  `shred/3` as the row delete a crypto-shred ends in.

Provenance: bead ece-60gg.
