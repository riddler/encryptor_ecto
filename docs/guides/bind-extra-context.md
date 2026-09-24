# How to bind extra identifiers into an encrypted field's context

Every encrypted field already binds `"table"` and `"column"`, and every
scoped one binds a `"tenant_ref"` the vault derives from the scope
selector. That is what makes a row's ciphertext non-substitutable: bytes
written for `cards.pan` under one scope fail authentication when they are
loaded as `cards.notes`, or under a different scope, whatever else an
attacker with database access can rearrange.

This guide is for the case where that is not enough - where a column's rows
are split across a boundary the schema does not express, and you want bytes
from one side of it to fail authentication on the other. The `:context`
option is how you say so.

It assumes you have an encrypted field working already. For what the
encryption context is and why it is authenticated rather than encrypted, read
`Encryptor.Context`; for the declaration rules this guide works inside, read
`Encryptor.Ecto.Binary` and ADR-0001 decision 4.

## Step 1. Decide whether the value belongs there

The context rides every message **in the clear** and is covered by the
header's authentication tag. So a pair you add is public to anyone holding a
ciphertext, unforgeable by anyone who does not hold the key, and permanent for
every row written while it is declared. Those three properties decide the
whole table:

| Bind it | Do not bind it |
|---|---|
| A stable classification of the column: `"purpose" => "pii"` | A secret, a token, a key fingerprint, a password hash - the context is not encrypted |
| A logical partition the column is split by and that a row never moves between: `"ledger" => "settlement"` | Anything that varies per row: a primary key, a row id, a user id, a request id, a timestamp |
| A deployment-independent name for the data's owner: `"app" => "payments"` | Anything mutable: a display name, a status, a plan tier, an email address |
| A value you can still produce, character for character, in five years | A schema prefix, a database name, a hostname, an environment name - a restore into a differently-placed database would stop reading |

Two of those rows are stronger than style advice.

**Per-row values are a performance defect, not a preference.** The serialized
context is hashed into the materials cache id, so each distinct context is its
own cache entry and its own cold-cache provider round trip - a key-store read
plus a root-vault decrypt, per row, forever (`Encryptor.Context`, "Nothing
that varies per row may go in the context"). `"table"` and `"column"` are
bounded by the schema; a row id is not. The vault cannot enforce this, because
it cannot tell a column name from a row id.

**Secrets in the context are disclosed by every row that carries them.** The
context is authenticated, not encrypted. Note that this package's own
exceptions carry context *key names* and never context values
(`Encryptor.Ecto.Error`) - that is a redaction rule about error rendering, and
it is not a reason to believe a value you put in the context is private. It is
in the bytes.

## Step 2. Declare it on the type module

`:context` is read from the `use`, not from the field, so it belongs to the
type module and every field naming that module gets it:

```elixir
defmodule Payments.Encrypted.SettlementBinary do
  use Encryptor.Ecto.Binary,
    vault: Payments.Vault,
    context: %{"purpose" => "pii", "ledger" => "settlement"}
end
```

The map must be string keys to string values; anything else raises an
`ArgumentError` when the declaration is frozen, which is while the schema
naming the type compiles. To bind different pairs on two columns, write two type
modules - `:table` and `:column` are the only declared values a field may
override at the field (`Encryptor.Ecto.Binary.init/2`).

Pairs compose as: whatever your vault's `:static_encryption_context`
configures, plus your `:context`, plus the declared `"table"` and `"column"`,
which win over a `:context` pair of the same name. The scope is not yours to
write: it passes to the vault as `key:` and the vault injects `"tenant_ref"`
itself.

If the pair you want is a classification of *everything* your vault encrypts
rather than of one column - `"app"`, usually, and often `"purpose"` - put it
in the vault's `:static_encryption_context` instead and leave `:context` out
of the type module. You get the same binding on every field with one place to
read it.

## Step 3. Know which refusals you have just bought

The vault composes the context on every `dump/3`, so a *declared* `:context`
pair that composes to something it refuses fails on the first write - as an
exception rather than a changeset error (`Encryptor.Ecto.Binary`,
"Failures raise; they never return `:error`"). The vault's own
`:static_encryption_context` is checked earlier and elsewhere: a reserved key
there fails the vault's start-time configuration validation, so it never
reaches a write at all. The table below is about the declaration:

| What you declared | What you get |
|---|---|
| A key starting `aws-crypto-` or `encryptor-` | `Encryptor.Ecto.EncryptError`, reason `{:reserved_context_key, key}` |
| `"tenant_ref"`, or `"tenant_id"` or `"scope_id"` on a `:scoped`-profile vault | the same, on the same key |
| A key your vault's static context already sets, at a *different* value | `Encryptor.Ecto.EncryptError`, reason `{:encryption_context_conflict, key}` |
| A key your vault's static context already sets, at the *same* value | Nothing. Redundant, not broken |
| An empty or non-UTF-8 key or value | `Encryptor.Ecto.EncryptError`, reason `{:invalid_context_value, key}` |
| More than 32 composed pairs, or over 4 KiB serialized | the same, reason `{:invalid_context_value, :count}` or `{:invalid_context_value, :too_large}` |

The size cap is the only mechanical backstop the vault has against a context
that grew without anyone deciding it should. It is not a budget to spend: the
serialized context is a per-row storage cost paid on every row forever.

Exercise a write in a test before you deploy the declaration. A refusal is
cheap on the first test run and expensive in a background job.

## Step 4. Accept that the value is now permanent

**A declared context pair is bound into every row written under it, and
changing the pair makes those rows unreadable.** There is no re-interpretation
and no fallback: the authentication tag covers the context, so a load composing
`"ledger" => "clearing"` against bytes written under `"ledger" => "settlement"`
fails authentication and raises `Encryptor.Ecto.DecryptError`. That is the
anti-substitution property working correctly, and it looks exactly like it
looks when an attacker moves a row.

So choose values that survive the things that change:

- **A rename is free if you pin.** Renaming a physical table or column costs
  nothing, because the declared values are frozen at declaration: pin the old
  strings with `:table` and `:column` and stored rows stay readable
  (`Encryptor.Ecto.Binary`, "What goes in the encryption context"). The same
  applies to a `:context` pair - keep the old string, whatever the business
  now calls the thing.
- **A real change is a full rewrite.** Adding, removing, or changing a
  `:context` pair is a context change, and therefore a data migration over
  every row in the column. Express it as a plan naming the *same* type module
  on both sides - `Encryptor.Ecto.Migration` accepts `from:` equal to `to:`
  precisely for this - and run it through `Encryptor.Ecto.Migrator`. The
  migrator constructs both sides' params itself, which is what makes the
  same-module rewrite expressible at all, and its probe compares the whole
  claimed context rather than parsing the header, so an unrewritten row is not
  mistaken for a finished one (`Encryptor.Ecto.Migrator.Pass`).

Budget the rewrite before you declare the pair. A pair that is right for
today's product boundary and wrong for next quarter's costs a production data
migration to correct.

## Step 5. Check what the deploy now declares

`Encryptor.Ecto.Declarations.list/1` answers "what does this deploy consider
encrypted, and under what context", which is otherwise spread across every
schema:

```elixir
Encryptor.Ecto.Declarations.list(apps: [:payments])
|> Enum.map(&{&1.table, &1.column})
```

One caveat worth knowing before you lean on a `:context` pair for separation:
`Encryptor.Ecto.Declarations.check_unique!/1` compares the declared
`{table, column}` pair and the physical column behind it, and does not credit
your extra pairs. Two schemas over the *same* physical column are exempt -
that is what keeps a read model or a partial schema from colliding with the
schema it mirrors - but two fields that differ only in `:context` are
cryptographically non-substitutable and will still be reported as a collision.
Fix such a pair by giving the fields distinct declared `"table"`/`"column"`
values - that is the property the check
is defending, and the extra context is additional binding rather than a
substitute for it.

## A worked example: a signup wizard's two funnels

A signup wizard stores `signups.email` for two products that share one table
and one scope. Nothing in the schema keeps a row of one funnel from being
written over a row of the other, and the funnel is a column on the row, so it
is not eligible for the context.

The right move is not a `:context` pair at all: it is two columns, each with
its own declared `"column"` value, or two tables. Reach for `:context` when
the boundary is a property of the *column* - every row in it, forever - and
for schema separation when the boundary is a property of the row. A context
pair cannot express a per-row fact, and the cache cost is what tells you so.
