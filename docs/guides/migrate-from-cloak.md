# How to migrate a host app off cloak_ecto

This guide takes a running multi-tenant application whose encrypted columns are
written by `cloak_ecto` and leaves it with those same columns written by this
package, with the application serving traffic throughout. It works unchanged for
a host leaving a hand-rolled encrypted `Ecto.Type`: cloak is the named case
because it is the common one, not because it is an integration.

It assumes you already know what changes when you make this move - per-tenant
keys, the encryption context, fail-closed tenant scope, and what a blind index
does and does not restore. If you do not,
[what changes when you move off cloak_ecto](../explanation/moving-off-cloak.md)
is that page, and it is worth reading before you run step 3.

The host in the examples is a payment application: a `cards` table with an
encrypted `pan` and an encrypted `notes`, a `signups` table with an encrypted
`email` and an A/B `variant` column, and one exact-match lookup - find a signup
by email, served today by a `Cloak.Ecto.SHA256` sibling column.

## Before you start

- **The legacy key material still exists and the legacy modules still read the
  rows.** A host whose cloak key is gone has rows that are already shredded.
  Nothing here can recover them, and the migration will classify every one of
  them `:undecryptable`.
- **Vault key material exists for every tenant** you are about to migrate, or
  can be provisioned in step 1. Provisioning is `encryptor`'s territory and
  this package has no verb that touches a key.
- **You can deploy twice**, which is what steps 2 and 3 are, and you can run a
  command against production from your release.
- **PostgreSQL.** The census SQL at the end is written in Postgres; the tasks
  themselves are adapter-agnostic.

Every command below is given in two forms. The **release `eval` form comes
first** and is the one to use: a rotation you can only run from a laptop
holding production credentials is the opposite of a control. The `mix` form is
the same call with an argument parser in front of it, for a host that runs
migrations from a build machine.

## The runbook at a glance

| # | Step | Reversible by |
|---|---|---|
| 0 | Finish or abandon any in-flight legacy key rotation | Nothing written |
| 1 | Provision vault key material for every tenant | Nothing to reverse; no host data touched |
| 2 | Deploy with both libraries in the tree, schema fields still naming the legacy type modules | Reverting the deploy |
| 3 | Deploy the type modules switched over with `legacy:` set | Reverting the deploy, **while no row has been written in the new format** |
| 4 | Dry run. Resolve every `:undecryptable` row and every `:migratable_unverified` count | Nothing written |
| 5 | Write. **Point of no return** | A reverse plan (below) or a restore |
| 6 | Verify over the whole scope. Exit 0 is the acceptance test | n/a |
| 7 | Replace the legacy lookup column. Not optional if it is unkeyed | Dropping the new columns; the old one is gone |
| 8 | One named commit: `legacy:` gone, the legacy library gone, the plan deleted | Reverting the commit |

The table says the point of no return is step 5, and in bulk it is. In practice
reversibility ends at **step 3**: the moment the new type modules are live,
ordinary application traffic starts writing new-format rows, and a revert leaves
rows the old modules cannot read. Treat the step 3 deploy as the decision.

## Step 0. Finish or abandon any in-flight legacy rotation

If your cloak vault is mid-rotation it has two ciphers configured, and both are
readable through the same type module, so nothing here breaks. Two migrations
at once make one report, which is the problem. Let the cloak rotation finish, or
stop it, before continuing.

Nothing is written in this step and there is nothing to check but your own
deploy state.

## Step 1. Provision vault key material for every tenant

Do this with `encryptor`'s own provisioning, for every tenant that has a row in
a table you are about to touch - including tenants that are offboarded but whose
rows are still present.

**If it differs:** a tenant with no key material fails at the first row of its
own, in step 4, with a vault error rather than a decrypt failure. That is a
provisioning gap, not a migration finding; go back and fill it.

## Step 2. Deploy with both libraries in the tree

Add this package beside `cloak_ecto` and deploy. Schema fields still name the
legacy type modules; nothing about how a row is read or written changes yet.

```elixir
# mix.exs - both, for now. Step 8 removes the second.
{:encryptor_ecto, "~> 0.1"},
{:cloak_ecto, "~> 1.2"}
```

**Expected:** an ordinary deploy, with no behaviour change and no new writes in
any new format.

**If it differs:** a compile failure here is a dependency conflict, and it is
better found now than between steps 3 and 5, which is the whole reason this is a
deploy of its own.

## Step 3. Switch the type modules over, with `legacy:` set

The type modules change; the schemas do not.

```elixir
defmodule MyApp.Encrypted.Binary do
  use Encryptor.Ecto.Binary,
    vault: MyApp.Vault,
    legacy: MyApp.Cloak.Encrypted.Binary
end

defmodule MyApp.Encrypted.String do
  use Encryptor.Ecto.String,
    vault: MyApp.Vault,
    legacy: MyApp.Cloak.Encrypted.String
end
```

`legacy:` makes reads tolerate both formats: the new load is attempted first,
always, and the legacy module is tried only when the new one fails with a
message-shaped failure. It is never a write path - a value read through the
legacy module and written back is written in the new format, so ordinary traffic
migrates rows on its own from this moment.

Wire the counter that tells you when the window has closed, in the same deploy:

```elixir
:telemetry.attach(
  "legacy-load-counter",
  [:encryptor_ecto, :legacy_load],
  fn _event, %{count: n}, %{table: table, column: column}, _config ->
    MyApp.Metrics.increment("encryptor_ecto.legacy_load", n, table: table, column: column)
  end,
  nil
)
```

The event's metadata is the table and the column and nothing else - no value, no
bytes, no reason, no tenant.

**Expected:** the deploy goes out, reads keep working on every row, and the
`legacy_load` counter climbs immediately. A counter that is flat at zero from the
first minute means the types are not actually being exercised, or `legacy:` did
not reach the module you thought it did.

**If it differs:** an exception naming a missing tenant or a missing context is
host misconfiguration and is deliberately loud - the legacy fallback is not
attempted for either, because answering a configuration bug with a successful
legacy read buys you a silent year of unmigrated rows. Fix the tenant resolution
and redeploy.

**While this window is open, an unmigrated row is read under the legacy scheme's
rules.** For a cloak host that means no encryption context and no per-tenant key
separation for those rows. The guarantee is per-row until the pass finishes,
which is why the window is meant to be short.

## Step 4. Rehearse with a dry run

Write the plan first. It is code, it is reviewed in a diff, and step 8 deletes
it. Generate the skeleton if you want a starting point:

```
$ mix encryptor.ecto.gen.plan --module MyApp.Encryption.CloakMigration
* creating lib/my_app/encryption/cloak_migration.ex
7 candidate fields across 4 schemas. It does not compile yet: finish every `tenant_from` and every `to:`, and delete the fields that are not encrypted. The file says which is which.
```

The generated file does not compile on purpose: every `tenant_from` names
`:TODO_tenant_column`, every `to:` is a comment, and the field list over-reports.
Finish it into something like this:

```elixir
defmodule MyApp.Encryption.CloakMigration do
  use Encryptor.Ecto.Migration, repo: MyApp.Repo

  rewrite MyApp.Payments.Card do
    tenant_from :merchant_id

    field :pan,
      from: MyApp.Cloak.Encrypted.Binary,
      to: MyApp.Encrypted.Binary,
      source_authenticated: true

    field :notes,
      from: MyApp.Cloak.Encrypted.String,
      to: MyApp.Encrypted.String,
      source_authenticated: true
  end
end
```

`source_authenticated:` is required on every field whose `from:` is not one of
this package's own vault-backed types, and the plan does not compile without it.
Write `true` when you have checked that the legacy cipher authenticates -
`Cloak.Ciphers.AES.GCM` does. Write `false` when it does not -
`Cloak.Ciphers.AES.CTR` does not - and add a `validate:` beside it. On another
rewrite in the same plan, a `signups.email` field on a CTR vault reads:

```elixir
    field :email,
      from: MyApp.Cloak.Encrypted.String,
      to: MyApp.Encrypted.String,
      source_authenticated: false,
      validate: &MyApp.Encryption.Checks.email_matches_stored_hash?/1
```

If you have a legacy hash column beside the field, recomputing it over the
loaded plaintext is the strongest validator available and it is free. It is also
the reason step 7 drops that column after the rewrite rather than before. The
sample output in the rest of this guide is from the two-field `Card` plan
above, which is why its `migratable_unverified` count stays at zero.

Add the checkpoint table in the same change, with your own migration on your own
deploy schedule:

```
$ mix encryptor.ecto.gen.migration
* creating priv/repo/migrations/20260828105920_create_encryptor_ecto_migration_checkpoints.exs
```

Then rehearse. A dry run performs every read, probe, decrypt and encrypt and
discards the write, so it is an exact rehearsal, including how long it takes.
Run it with `on_error: :continue` the first time: the default halts at the first
unreadable row, and what you want from a rehearsal is the complete census of
problems rather than the first one.

```
$ bin/my_app eval '
  {status, report} =
    Encryptor.Ecto.Migrator.run(MyApp.Encryption.CloakMigration,
      mode: :dry_run, on_error: :continue)

  IO.inspect(report.counts, label: "counts")
  IO.inspect(report.failures, label: "failures")
  if status == :error, do: System.halt(1)
'
counts: %{
  null: 412,
  undecryptable: 3,
  already_target: 1908,
  migratable: 2204551,
  migratable_unverified: 0
}
failures: [
  %{
    id: 88123,
    reason: :load_failed,
    field: :pan,
    schema: MyApp.Payments.Card
  },
  ...
]
$ echo $?
1
```

The same pass through `mix`:

```
$ mix encryptor.ecto.migrate MyApp.Encryption.CloakMigration --mode dry-run --on-error continue
mode: dry_run
null: 412
already_target: 1908
migratable: 2204551
migratable_unverified: 0
undecryptable: 3
concurrent: 0
failures: 3
  MyApp.Payments.Card.pan id=88123 reason=:load_failed
  MyApp.Payments.Card.pan id=88124 reason=:load_failed
  MyApp.Payments.Card.pan id=91002 reason=:load_failed
$ echo $?
1
```

**Expected:** exit 0 with `undecryptable: 0`, and `already_target` non-zero if
step 3 has been live for a while - ordinary traffic has been migrating rows on
its own. A failure line carries the schema, the field, the primary key and the
reason, and never a value.

**If it differs:**

| What you see | What to do |
|---|---|
| Exit 1 with `undecryptable` rows | Investigate before writing anything. This is the dry run doing its job. Find the rows by the primary keys in the failure list, decide what they are - a shredded tenant, a corrupt row, a column that was never cloak's - and either fix them or exclude their tenant with `except_tenants:` / `--except-tenant`. Do **not** answer this with `on_error: :continue` in write mode |
| A non-zero `migratable_unverified` | Every row of a field you declared `source_authenticated: false`. The pass exits on failures, so this alone is still exit 0 - but it will keep saying `migratable_unverified` in every later report, because no authentication tag ever confirmed those rows, and step 6's verification does treat it as not-in-the-target-state. Confirm your `validate:` is the strongest check you can write, then proceed |
| Exit 2 and a message about `source_authenticated: false` | The pass refuses `mode: :write` for an acknowledged-unauthenticated field with no `validate:`, before it reads a row. A dry run and a verification are unaffected. Declare `validate:`, or narrow the run with `only:` |
| Exit 2 naming the checkpoint table | The table is not there. Run the generated migration, or run with `checkpoint: :none` / `--no-checkpoint`, where every run is a full scan |
| The pass takes far longer than the change window allows | Raise `batch_size:` from its default of 500, and plan to resume. Do not provision a throttled migration repo out of cloak habit: this pass is single-process by design and needs one connection |

## Step 5. Run the pass

This is the point of no return in bulk. The application keeps serving.

```
$ bin/my_app eval '
  {status, report} =
    Encryptor.Ecto.Migrator.run(MyApp.Encryption.CloakMigration,
      mode: :write, except_tenants: ["tnt_offboarded"])

  IO.inspect(report.counts, label: "counts")
  IO.inspect(report.failures, label: "failures")
  if status == :error, do: System.halt(1)
'
```

```
$ mix encryptor.ecto.migrate MyApp.Encryption.CloakMigration --mode write --except-tenant tnt_offboarded
mode: write
null: 412
already_target: 1908
migratable: 2204551
migratable_unverified: 0
undecryptable: 0
concurrent: 37
failures: 0
$ echo $?
0
```

`concurrent` counts rows the application rewrote between the migrator's read and
its write. They are not failures and not a class: every write is a
compare-and-swap against the exact bytes that were read, so such a row was left
alone rather than clobbered with a re-encryption of stale plaintext, and it was
already counted once when it was read.

**Expected:** exit 0, `failures: 0`, and `migratable` equal to what the dry run
predicted less whatever ordinary traffic migrated in the meantime.

**If it differs:**

| What you see | What to do |
|---|---|
| The pass halted partway, with failures listed | The default is `on_error: :halt`, and it stopped at the first row it could not handle. Read the counts as an upper bound rather than a ledger: the batch it halted in is rolled back and its cursor is not recorded, so the report can overstate what was persisted by up to one batch. Resolve those rows, then resume - resuming starts from the last committed checkpoint, so the rolled-back batch is simply done again |
| A `validate:` rejection | The host's own check refused a loaded value. On an unauthenticated legacy cipher these are the rows the whole acknowledgement exists for: an AEAD source would have called them `:undecryptable` on its own. Treat each as a data question, not a migration question |
| The pass died - deploy, restart, connection loss | Re-run it. Every row is probed before it is rewritten, so a re-run is safe by construction; the checkpoint only makes it fast. Add `resume: true` / `--resume` to start after the recorded cursor |
| You need to watch it from outside | Use the census SQL below. It needs no key and no application |

Resuming reads the cursor recorded after each batch, inside that batch's own
transaction:

```
$ mix encryptor.ecto.migrate MyApp.Encryption.CloakMigration --mode write --resume
```

`--resume` with `--no-checkpoint` is refused: resuming from a checkpoint that was
never written is a request with no meaning.

## Step 6. Verify over the whole scope

This is the acceptance test.

```
$ bin/my_app eval '
  {status, report} =
    Encryptor.Ecto.Migrator.verify(MyApp.Encryption.CloakMigration, sample: :all)

  IO.inspect(report.counts, label: "counts")
  if status == :error, do: System.halt(1)
'
```

```
$ mix encryptor.ecto.verify MyApp.Encryption.CloakMigration --sample all
mode: verify
null: 412
already_target: 2204551
migratable: 0
migratable_unverified: 0
undecryptable: 0
concurrent: 0
failures: 0
$ echo $?
0
```

**Expected:** exit 0, with every row `already_target` or `null`.

**If it differs:** verification is deliberately stricter than the pass. A table
of readable legacy rows is a green dry run and a **red** verification, because
"every row is in the target state" is the question the acceptance test has to
ask. Exit 1 with a non-zero `migratable` means rows were missed - a tenant you
excluded, a prefix you did not visit, or a field you narrowed away with `only:`.
Re-run step 5 for them. A verification never halts on a row, so a table with
unreadable rows gives you a count rather than a report that stops at the first.

Keep running this on a schedule afterwards. Exit 0 over `sample: :all` is also
the primary signal that the mixed window has closed and step 8 is due.

## Step 7. Replace the legacy lookup column

Cloak's answer to exact-match lookup on an encrypted column is a deterministic
sibling column, so a host that needed lookups arrives here with one. It is
**replaced, not supplemented**: adding a keyed index beside an unkeyed one fixes
nothing while the unkeyed one remains.

Start by finding out which of three cases you are in, because it decides whether
this step is optional and what its last action is. Read the type module named on
the sibling field in your cloak-era schema.

### Which case you are in

| Sibling column | What a dump discloses | What you do |
|---|---|---|
| `Cloak.Ecto.SHA256` - unsalted, unkeyed | Every value whose plaintext is guessable, to anyone holding the dump and no key at all | **Drop it. Not optional**, whether or not you adopt an index |
| `Cloak.Ecto.HMAC` or `Cloak.Ecto.PBKDF2` - keyed, one global key | Nothing without the key; with the key, equality across every tenant and every table sharing that key | Replace it with a declared index, then drop it |
| None | - | Adopt an index or do not, freely |

This is ADR-0004 decision 9. The three are not variations on one disposition,
and treating them as one is how the unkeyed column survives a migration whose
whole purpose included removing it.

**`Cloak.Ecto.SHA256` is a fingerprint with no key in it.** Anyone holding a
dump - a backup, a replica, a stolen snapshot, a support export - recomputes
`sha256(value)` for every candidate value they care to guess and matches it
against the column, with no key material and no access to your application. The
columns hosts most want to look up on are email addresses, phone numbers and
tax identifiers, which are exactly the guessable spaces. This is the unkeyed
folk pattern `Encryptor.Ecto.BlindIndex`'s *Security properties* names as the
thing a keyed index exists to replace: its second table row, "the dump, and a
guess at a plaintext they think is present", is the property this column does
not have. Encrypting the value column and leaving this one beside it means the
ciphertext is doing nothing for any guessable value.

So the drop is unconditional. If you decide not to adopt a blind index at all,
you still drop the column, and you lose that lookup - which is the honest price
of a disclosure you were paying for it all along.

**A keyed `Cloak.Ecto.HMAC` or `Cloak.Ecto.PBKDF2` column is a real blind
index**, and a dump alone tells an attacker nothing about the values in it. What
it lacks is the domain separation ADR-0003 decision 2 builds into the HKDF
`info` string. It is derived from one key configured for the deployment, so:

- two tenants storing the same value produce identical bytes, which is exactly
  the `scope: :global` column of the *Security properties* table - equality
  structure across the whole table rather than within a tenant;
- two columns holding the same value produce identical bytes, so a dump can be
  joined across every table configured with that key - a `signups.email_hash`
  against a `contacts.email_hash` - which a per-column `info` string makes
  structurally impossible;
- a staging database restored from a production backup keys the same way, since
  there is no per-deployment `:derivation_salt` under the construction;
- and it does not shred with a tenant's key. Destroy a tenant's vault key
  material and this column still answers "does this tenant have a row with
  value X" for anyone holding the legacy key, which is the last row of that
  table and the reason `scope: :global` has to be written out loud.

Replacing it is therefore worth doing even though it is not the emergency the
unkeyed case is. Lookups keep working through the legacy column while the new
one backfills, so the switchover has no gap in it.

**No sibling column** means you are choosing, not repairing, and the choice has
its own cost - a blind index is a leakage decision paid per column and
permanently. Reserve one for high-cardinality exact-match keys. In the example
host, `signups.email` earns an index and the A/B `variant` column does not: a
two-value column publishes its own distribution to anyone counting rows per
distinct index value, with no key at all. `Encryptor.Ecto.BlindIndex`'s *What
this does not defend against* is the full statement, and an index on a
low-cardinality column is a defect there rather than a tradeoff.

### The order, which is fixed

Both of the tempting alternatives are wrong in a way that is invisible at the
time:

1. Add the new index column in your own migration, and declare it on the schema.

   ```elixir
   import Encryptor.Ecto.BlindIndex

   schema "signups" do
     field :merchant_id, :string
     field :variant, :string

     field :email, MyApp.Encrypted.String
     field :email_index, :binary
     blind_index :email, :email_index, normalize: :email
   end
   ```

   The column is yours - this package writes no migrations and adds no fields.
   It is a nullable `:binary`, 32 bytes at the default `:bits`, and it is added
   beside the legacy one rather than over it:

   ```elixir
   defmodule MyApp.Repo.Migrations.AddSignupEmailIndex do
     use Ecto.Migration

     def change do
       alter table(:signups) do
         add :email_index, :binary
       end

       create index(:signups, [:merchant_id, :email_index])
     end
   end
   ```

   On Postgres that is:

   ```sql
   ALTER TABLE "signups" ADD COLUMN "email_index" bytea;
   CREATE INDEX "signups_merchant_id_email_index_index"
       ON "signups" ("merchant_id", "email_index");
   ```

   The database index is on `(merchant_id, email_index)` rather than on the
   index column alone, because every lookup is already inside a tenant.

   Leave the legacy column in place in this migration. It is still serving
   lookups in the keyed case, and it is still the validator in both.

2. Write the index from your changesets with
   `Encryptor.Ecto.BlindIndex.put_index/3`, and read it with `where_eq/3`. Both
   compute through one place, so a write and a read cannot disagree about
   normalization or width.

   ```elixir
   def changeset(signup, attrs) do
     signup
     |> cast(attrs, [:email, :variant])
     |> put_index(:email, :email_index)
   end

   def by_email(email) do
     MyApp.Signup |> where_eq(:email, email) |> MyApp.Repo.one()
   end
   ```

   Keep writing the legacy column in this deploy too, from the same changeset.
   That is what makes the switchover gapless, and it is the state step 4 ends.
   On a truncated index (`bits: 64`, `128` or `192`) the read helper is
   `where_eq_candidates/3` instead and it returns a set you filter after
   decrypting - the name is the contract, so a call site cannot forget.

   Audit every other write path while you are here. Encryption lives in the
   type and cannot be forgotten; the index lives in the call site and can. A
   bulk insert, an admin script or a second changeset function that skips
   `put_index/3` produces a row whose lookup silently misses.

3. Backfill the index column, batched and in tenant scope, **after** the
   ciphertext rewrite of step 5 is verified. Two backfills at once make one
   report, and a failure in either stops being attributable to one of them.

   The backfill is a decrypt-and-recompute pass over your own rows, so it needs
   the tenant scope the index derivation reads. There is no way around the
   decrypt: the index is computed from plaintext and nothing in the stored
   ciphertext can be transformed into one.

4. Switch reads over, and only then drop the legacy column - **in the same
   migration that stops writing it**, and not before.

   Not before, because while step 4's `validate:` was recomputing it, it was the
   best integrity check available on an unauthenticated source. Not later,
   because a column nobody writes but nothing dropped is a column that goes
   stale silently while still disclosing everything it disclosed before.

   ```elixir
   defmodule MyApp.Repo.Migrations.DropSignupEmailHash do
     use Ecto.Migration

     def change do
       alter table(:signups) do
         remove :email_hash, :binary
       end
     end
   end
   ```

   ```sql
   ALTER TABLE "signups" DROP COLUMN "email_hash";
   ```

   Before you run it, confirm the new column is fully backfilled. This is SQL
   over your own tables, it needs no key, and it is the check that catches a
   backfill that skipped a tenant:

   ```sql
   -- rows with a value but no index: must be zero before the drop
   SELECT count(*) AS unindexed
   FROM "signups"
   WHERE "email" IS NOT NULL
     AND "email_index" IS NULL;

   -- and per tenant, which is where a partial backfill actually shows up
   SELECT "merchant_id",
          count(*) FILTER (WHERE "email_index" IS NOT NULL) AS indexed,
          count(*) FILTER (WHERE "email" IS NOT NULL) AS encrypted
   FROM "signups"
   GROUP BY 1
   HAVING count(*) FILTER (WHERE "email_index" IS NOT NULL)
        < count(*) FILTER (WHERE "email" IS NOT NULL);
   ```

   The second query returning no rows is the precondition. A tenant listed
   there is a tenant whose lookups break the moment the legacy column is gone.

   In the unkeyed case there is nothing to preserve and no reason to wait past
   step 6's exit 0: if you are not adopting an index, this migration is the
   whole of step 7. In the keyed case, the legacy key outlives the column
   unless you remove it - it is cloak configuration, and step 8 is where it
   goes with the rest of the legacy vault.

**Expected:** lookups return the same rows they did through the legacy column,
for values that normalize the same way.

**If it differs:** a lookup that finds nothing is almost always normalization -
the legacy hash and the new index were computed over differently normalized
inputs. Normalization is lossy and directional, and changing it invalidates every
value already stored in the column.

Four facts about this column decide when you can do it, rather than how:

- Rotating the vault's `:derivation_salt` invalidates every blind index in the
  deployment: it is a full reindex, not a rekey.
- Bumping an index's `:version`, changing its `:normalize`, or changing its
  `:bits` invalidates that column for the same reason. Each is a reindex.
- Rotating a **tenant's key** requires reindexing that tenant's rows as well.
  The derivation consults the current key material, so that tenant's index
  keys change without any declaration changing, and lookups for that tenant
  miss until the reindex lands. `Encryptor.Ecto.BlindIndex`'s own
  documentation is the full statement.
- `:slow` (Argon2id before the HMAC) is declared but not available: it is
  accepted and carried, and it computes nothing, because the vault exposes no
  Argon2id surface. Do not plan around it.

**A dump taken before the drop still contains the old column.** That is a fact
about your backups, and this package cannot fix it. It is worth saying plainly
in the unkeyed case: every backup taken while `email_hash` existed still
discloses every guessable email address in it, to whoever can read that backup,
forever. Dropping the column stops the disclosure growing; it does not undo it.
Whether that means re-taking your backup set, shortening its retention, or
accepting it, is your call and your retention policy's, not this package's.

The full leakage table - what an attacker learns from a `scope: :tenant` index
and from a `scope: :global` one, holding a dump, a guess, one tenant's key, or a
retained dump after a shred - is `Encryptor.Ecto.BlindIndex`'s *Security
properties*, at the declaration where a reviewer meets it. The records behind
this step are [ADR-0004 decision 9](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0004-migration-from-cloak.md) for the
three dispositions and the ordering rule, and
[ADR-0003](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0003-blind-index.md) for the construction.

## Step 8. Close the window in one named commit

The precondition is evidence, not memory: step 6 exits 0 over the whole scope,
and the `[:encryptor_ecto, :legacy_load]` counter has read zero for a full
retention period. A quiet hour is not enough - a table with a cold partition
nobody reads reports zero while still holding legacy rows.

The window is per-field, and so is its end. A host with twelve encrypted columns
finishes eleven and still has one legacy reader open; the counter's metadata
names the table and the column so the last one is identifiable.

In one commit:

- drop `legacy:` from every type module,
- drop `cloak_ecto` from `mix.exs`,
- delete the plan module,
- delete the legacy type modules and their vault, once nothing names them.

```elixir
defmodule MyApp.Encrypted.Binary do
  use Encryptor.Ecto.Binary, vault: MyApp.Vault
end
```

**Expected:** the suite is green, the deploy is ordinary, and the `legacy_load`
counter stays at zero because there is no longer an event to emit.

**If it differs:** a decrypt failure after this deploy is a row that was never
migrated, and it is now unreadable. Revert the commit - which is why this step is
last, and why the legacy key material and modules had to survive until now.

## If you must go back: the reverse plan

There is no rollback tooling, deliberately: an automated rollback of a security
migration is a mechanism whose only rehearsal is the emergency it exists for.
What there is is a symmetry. The migrator constructs both sides' parameters
itself, so a plan with `from:` and `to:` swapped is a valid plan, and running it
walks the table back.

```elixir
defmodule MyApp.Encryption.CloakRollback do
  use Encryptor.Ecto.Migration, repo: MyApp.Repo

  rewrite MyApp.Payments.Card do
    tenant_from :merchant_id

    field :pan,
      from: MyApp.Encrypted.Binary,
      to: MyApp.Cloak.Encrypted.Binary
  end
end
```

Its preconditions, all of which step 8 destroys:

- the legacy key material still exists,
- the legacy type modules are still in the tree,
- `cloak_ecto` is still a dependency.

Rehearse it with `mode: :dry_run` exactly as you rehearsed the forward pass. No
`source_authenticated:` declaration is needed on a field whose `from:` is one of
this package's own types - that side authenticates, and the package can prove it.

## Watching a pass without a key

The census is SQL over your own tables. It connects to nothing, decrypts nothing,
and is what you hand a DBA who should not be handed a key. Render it from the
plan:

```
$ bin/my_app eval '
  MyApp.Encryption.CloakMigration
  |> Encryptor.Ecto.Migrator.Census.queries()
  |> Encryptor.Ecto.Migrator.Census.script()
  |> IO.puts()
'
-- "cards"."pan": format census, grouped on 4 bytes
SELECT substring("pan" from 1 for 4) AS header,
       count(*) AS rows
FROM "cards"
WHERE "pan" IS NOT NULL
GROUP BY 1
ORDER BY 2 DESC;

-- "cards"."pan": nothing became NULL or empty
SELECT count(*) AS rows,
       count("pan") AS non_null,
       count(*) FILTER (WHERE octet_length("pan") = 0) AS empty
FROM "cards";

-- "cards"."pan": rotation progress for one tenant
SELECT count(*) FILTER (
         WHERE substring("pan" from 1 for 4) = :current_header
       ) AS done,
       count(*) FILTER (WHERE "pan" IS NOT NULL) AS total
FROM "cards"
WHERE "merchant_id" = :tenant;

-- ... and the same three queries again for "cards"."notes", and for every
-- other field of every other rewrite the plan declares.
```

Substitute `:tenant` with the tenant you are watching, and `:current_header` with
the prefix the format census shows **growing** - that is how you get it without a
key.

**The prefix is four bytes, and one byte would lie.** A cloak envelope opens with
a reserved `0x01` byte and this package's messages open with a version byte of
their own, so a census keyed on the first byte alone can read as identical across
both formats: one header, all migrated, over a table that is half legacy. Do not
narrow it. The queries group rather than test, so a host whose formats collide
further in gets a census that looks wrong rather than one that lies.

Run the integrity query before the pass and after it, and compare. Nothing should
have become `NULL` and nothing should have become empty.

## Related

- [What changes when you move off cloak_ecto](../explanation/moving-off-cloak.md) -
  the semantics behind every step here.
- `mix help encryptor.ecto.migrate` and `mix help encryptor.ecto.verify` - the
  full flag tables and exit codes, which live with the code that parses them.
- [ADR-0004](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0004-migration-from-cloak.md) - the record this runbook
  renders.
