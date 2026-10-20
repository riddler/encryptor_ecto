# How to declare and query a blind index

This guide adds an exact-match lookup to an encrypted column. A blind index
stores a keyed fingerprint of the plaintext in a second column beside the
encrypted one, so that equality on plaintext becomes equality on the
fingerprint. It answers "which rows hold this value" and nothing else: no
`LIKE`, no prefix, no range, no ordering.

It assumes a schema with an encrypted field that has a scope, as in the
README's *Basic usage*. A host moving off an unkeyed `Cloak.Ecto.SHA256`
column does this work as step 7 of
[the cloak migration](migrate-from-cloak.md), which orders it against the
rest of the migration.

## Before you start

Decide that the column earns an index. A blind index is a leakage decision
paid per column and permanently: anyone holding a dump can count how many rows
share each value, and read a skewed column off those counts with no key at
all. Reserve one for **high-cardinality exact-match keys** - a serial number,
an external reference, a national identifier. An index on a column with few
distinct values is a defect, not a tradeoff.
[What a blind index leaks](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.BlindIndex.html#module-security-properties)
is the table to read before you go on.

The field you index must be one of this package's encrypted types. The
declaration is refused at compile time for any other field.

## Step 1. Add the index column

The index column is an ordinary column you declare in your own migration.
This package writes no migrations. It is a nullable `:binary`, 32 bytes at the
default width:

```elixir
defmodule MyApp.Repo.Migrations.AddRecordHandleIndex do
  use Ecto.Migration

  def change do
    alter table(:records) do
      add :handle_index, :binary
    end

    create index(:records, [:scope_id, :handle_index])
  end
end
```

The database index is on `(scope_id, handle_index)` rather than on the index
column alone, because a per-scope index is only ever queried inside one scope.

## Step 2. Declare the index on the schema

Add the column as a field, and declare the index beside the encrypted field it
fingerprints:

```elixir
defmodule MyApp.Records.Record do
  use Ecto.Schema
  import Encryptor.Ecto.BlindIndex

  schema "records" do
    field :scope_id, :string

    field :handle, MyApp.Encrypted.String
    field :handle_index, :binary
    blind_index :handle, :handle_index, normalize: :downcase
  end
end
```

The declaration puts the index's normalization and key derivation in one
place, so the write side and the read side cannot disagree about either.

Choose these options now, because changing any of them later invalidates every
value already stored in the column and is a reindex:

| Option | Default | What to decide |
|---|---|---|
| `:normalize` | `:none` | What the fingerprint is computed over. `:none` is byte-exact; `:trim`, `:downcase` and `:digits` are the other common built-ins, and `{module, function}` names your own. A lookup then finds every value that normalizes the same, so an index hit is not proof of byte equality |
| `:bits` | `256` | The stored width. `64`, `128` and `192` truncate the fingerprint and change which query helper you call in Step 4 |
| `:slow` | `false` | `true` runs Argon2id before the fingerprint. It needs a vault that declares `:slow_hash` and `:argon2_elixir` in your deps |
| `:version` | `1` | Bump it to rotate the index key into a second column |
| `:derive` | `:per_scope` | Keep it. `:global` makes the column's equality structure span every scope and survive a scope's shred |

`Encryptor.Ecto.BlindIndex` lists every option. The schema fails to compile
when:

- the source is not a field on the schema, or not an encrypted field of this
  package;
- the index column is not a field on the schema, or is itself an encrypted
  field;
- the source field is declared `scope: :none` and the index does not say
  `derive: :global`;
- two declarations share an index name, or a source field and column pair.

## Step 3. Write the index from every changeset

Call `put_index/3` after `cast/3`:

```elixir
def changeset(record, attrs) do
  record
  |> cast(attrs, [:handle])
  |> put_index(:handle, :handle_index)
end
```

`put_index/3` computes the column from the changed source field, under the
scope in force. Three behaviours are worth knowing:

- A changeset that does not change the source leaves the stored index alone.
- A source set to `nil` sets the index to `nil`.
- A source set to `""` gets a real index value, the same for every empty
  string in the scope.

With no scope set it raises `Encryptor.Ecto.MissingScopeError`, like any other
scoped write.

Then find every other path that writes the table: a second changeset function,
a bulk insert, an admin script. Encryption lives in the type and cannot be
forgotten; the index lives in the call site and can. A row written without
`put_index/3` has an empty or stale index column, and a lookup for it silently
finds nothing. Nothing in this package checks your write paths for you.

## Step 4. Query by the index

Use `where_eq/3` on a query over the schema, inside the scope:

```elixir
import Encryptor.Ecto.BlindIndex

def by_handle(scope_id, handle) do
  Encryptor.Ecto.Scope.wrap(scope_id, fn ->
    MyApp.Records.Record
    |> where_eq(:handle, handle)
    |> MyApp.Repo.one()
  end)
end
```

The value is normalized the same way as on write, then fingerprinted. The
helper expands to an equality on the index column and nothing else.

**Expected:** the query returns the row whose `handle` normalizes to the same
value as the one you asked for, decrypted by the type as usual.

Read these before you rely on it:

- `where_eq/3` raises `Encryptor.Ecto.MissingScopeError` when the query is
  *built* outside a scope, rather than returning a query that matches nothing.
- The queryable must be a schema module. A table-name string or a subquery has
  no declaration to read, and the helper raises `ArgumentError`.
- On a truncated index (`:bits` below `256`), `where_eq/3` raises
  `ArgumentError` and names `where_eq_candidates/3`. That helper returns
  candidates, so filter them after decrypting.
- When a field has two indexes, as during a rotation, the three-argument forms
  refuse to choose. Name the column: `where_eq(Record, :handle, :handle_index, value)`.
- `compute/3` returns the fingerprint itself, for a query you build by hand.
  Treat it like plaintext and never log it: anyone who reads it can confirm
  that value is present.

## Step 5. Backfill the rows that already exist

Rows written before the index existed have a `NULL` index column, so a lookup
cannot find them. There is no way to derive the fingerprint from the stored
ciphertext: the backfill decrypts each row and recomputes under its own scope.

A plan that rewrites the column can fold the index into the same update with
the `index:` option; `Encryptor.Ecto.Migration` shows it. For rows that are
already in the target state, recompute from the changeset:

```elixir
def backfill_index(record) do
  Encryptor.Ecto.Scope.wrap(record.scope_id, fn ->
    record
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.force_change(:handle, record.handle)
    |> put_index(:handle, :handle_index)
    |> MyApp.Repo.update!()
  end)
end
```

`force_change/3` is there because `put_index/3` skips a source that did not
change. Run the function over the rows in batches, one scope at a time, with
every scope's rows loaded under that scope.

## Step 6. Check the backfill

This is SQL over your own tables and needs no key. Rows with a value but no
index must be zero:

```sql
SELECT count(*) AS unindexed
FROM "records"
WHERE "handle" IS NOT NULL
  AND "handle_index" IS NULL;
```

A partial backfill shows up per scope:

```sql
SELECT "scope_id",
       count(*) FILTER (WHERE "handle_index" IS NOT NULL) AS indexed,
       count(*) FILTER (WHERE "handle" IS NOT NULL) AS encrypted
FROM "records"
GROUP BY 1
HAVING count(*) FILTER (WHERE "handle_index" IS NOT NULL)
     < count(*) FILTER (WHERE "handle" IS NOT NULL);
```

**Expected:** no rows from the second query. A scope listed there is a scope
whose lookups miss.

## If a lookup finds nothing

| Symptom | Likely cause |
|---|---|
| The row exists and `where_eq/3` returns nothing | The row was written without `put_index/3`, or before the index existed. Run Step 6 |
| Every lookup in one scope misses after that scope's key was rotated | The index key derives from the scope's current key material, so that scope's index columns must be reindexed |
| Every lookup misses after a deploy that touched the index declaration | `:normalize`, `:bits`, `:version` or `:slow` changed, or the vault's `:derivation_salt` did. Each invalidates the stored values |
| `ArgumentError` naming `where_eq_candidates/3` | The index is truncated. Call that helper and filter after decrypting |
| `ArgumentError` about two indexes on one field | Name the index column in the four-argument form |

Changing `:normalize`, `:bits`, `:version` or `:slow`, rotating the vault's
`:derivation_salt`, and rotating a scope's key are each a reindex over rows
decrypted under their scope. For the first three, add a second index column
beside the first, backfill it, switch reads to it, then drop the old one. The
rotation of a scope's key has no supported sequence today beyond reindexing
that scope. [The API reference](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.BlindIndex.html)
states each case.

## See also

- [What a blind index leaks](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.BlindIndex.html#module-security-properties):
  what a dump, a dump plus one scope's index key, and a retained dump after a
  shred each reveal.
- [The normalizers](https://hexdocs.pm/encryptor_ecto/Encryptor.Ecto.BlindIndex.Normalizer.html):
  the built-in set and what each one drops.
- [ADR-0003](https://github.com/riddler/encryptor_ecto/blob/main/docs/adr/0003-blind-index.md):
  the decisions behind the construction.
