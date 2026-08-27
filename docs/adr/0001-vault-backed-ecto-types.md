# ADR-0001: cloak_ecto-shaped vault-backed types, with tenant context from an explicit process scope

Status: proposed (2026-08-26)

## Context

This package exists to put field-level encryption behind an `Ecto.Type`, so
that a schema field is declared encrypted once and every read and write in the
application goes through the vault without the calling code knowing. That is
exactly what `cloak_ecto` does today, and it is the shape the Elixir ecosystem
already has in its fingers.

**The shape is the migration story.** Every host this package is plausibly for
is already on `cloak_ecto`. Those hosts have a module per encrypted type:

```elixir
defmodule MyApp.Encrypted.Binary do
  use Cloak.Ecto.Binary, vault: MyApp.Vault
end
```

and a schema field that names it. If this package keeps that surface
byte-for-byte apart from the module namespace, migrating is a two-line swap in
the type module plus a data migration (the forthcoming re-wrap and
rotation record, ece-56a) - and crucially, *the schemas do not change at
all*. If the surface drifts, every schema in the host changes and the
migration becomes a project.
This record therefore treats "same shape as `cloak_ecto`" as a hard constraint
and only deviates where the underlying encryption model makes the old shape
wrong.

**The underlying encryption model is not cloak's.** Where Cloak's ciphers take
a plaintext and give back a ciphertext, the `encryptor` vault (enc-ADR: the
vault layer) takes a plaintext *and an encryption context*, and binds that
context into the message as additional authenticated data. The
encryption-context convention (enc-ADR: the encryption-context convention)
standardizes that context as identifying keys - tenant, table, column - so that
a ciphertext lifted out of one row and dropped into another *fails
authentication* rather than decrypting into the wrong place. That anti-
substitution property is the main reason to prefer this stack over cloak, and
it is worth nothing at all if the Ecto layer does not populate the context
correctly, on every single dump, with no way for a caller to forget.

So the central design question of this package is not the type surface. It is:
**where does the encryption context come from, at the moment Ecto calls
`dump/3`?**

Two thirds of the answer are structural. `Ecto.ParameterizedType.init/1`
receives the options a field was declared with *plus* `:schema` and `:field`,
which means the type module can bake the table (`schema.__schema__(:source)`)
and the column into its params at declaration time. Nobody has to pass those,
nobody can get them wrong, and they cost nothing at runtime.

The last third has no such answer. **`tenant_id` is not a property of the
field; it is a property of the request.** And an `Ecto.Type` callback is one of
the most context-starved positions in the whole stack: `dump/3` receives the
value, a dumper function, and the type params. It does not receive the struct,
the changeset, the repo, the query, or any caller-supplied options. Nothing a
host does at the call site is visible from inside the type unless it travels
out of band.

Three forces bear on how that gap gets closed.

**Fail-closed beats fail-convenient.** The failure mode of guessing wrong here
is encrypting a tenant's row under another tenant's key, or - worse in a
compliance conversation - a decrypt path that quietly reads across a tenant
boundary. Any mechanism with a silent default is a mechanism that produces
that outcome under load, in the one code path nobody exercised.

**The AAD is a backstop, not a substitute.** Because tenant rides the context,
a wrong tenant at *decrypt* time is an authentication failure, not a wrong
answer. That is a genuine safety net and it changes the risk calculus for
out-of-band mechanisms: the worst realistic outcome of a mis-scoped read is a
loud error. It does not help at *encrypt* time, where a wrong tenant produces a
durably wrong row.

**Hosts are not all multi-tenant.** A single-key application should not be made
to carry tenancy machinery, and a genuinely global field inside a multi-tenant
host (a shared reference table) must be expressible - but as a declaration
somebody wrote on purpose, not as the default that happens when nothing is
configured.

## Decision

**1. Three types, `cloak_ecto`'s shape exactly.** `Encryptor.Ecto.Binary`,
`Encryptor.Ecto.Map`, and `Encryptor.Ecto.String` are `use`-able modules that
define a host type module:

```elixir
defmodule MyApp.Encrypted.Binary do
  use Encryptor.Ecto.Binary, vault: MyApp.Vault
end
```

The generated module implements `Ecto.ParameterizedType`. Schema fields name
the host's module, never this package's:

```elixir
field :tax_id, MyApp.Encrypted.Binary
```

`Encryptor.Ecto.String` is `Binary` with a `String.t()` cast arm;
`Encryptor.Ecto.Map` is `Binary` over a serialized map (decision 8). Other
`cloak_ecto` types (`Integer`, `Float`, `Date`, `DateTime`, `NaiveDateTime`,
`Time`) are deliberately **not** in the founding set. They are mechanical
wrappers over `Binary` with a cast/parse pair, and adding them is an
implementation bead, not a decision.

**2. The column is `:binary`, always.** `type/1` returns `:binary`, for every
one of the three types, whatever the plaintext was. Migrations declare
`:binary`. Nothing in the stored bytes is readable, sortable, or comparable by
the database, and this record does not pretend otherwise (decision 10).

**3. The option set is small and closed.** `use` accepts:

| Option | Required | Meaning |
|---|---|---|
| `:vault` | yes | The `Encryptor.Vault` module this type encrypts through |
| `:tenant` | no | Tenant-context strategy: `:scope` (default), `:none`, or a module implementing `Encryptor.Ecto.TenantContext` (decision 5) |
| `:context` | no | Static extra context pairs merged into every operation, e.g. `%{"purpose" => "pii"}` |
| `:json` | Map only | Serializer module, default `Jason` (decision 8) |

Unknown options raise at compile time. There is no `Application` env fallback
for `:vault`: the vault is named at the declaration or the module does not
compile. (Vault *configuration* - keys, providers, caching - is resolved inside
the vault per the upstream vault record; that is not this layer's business.)

**4. Table and column context are derived, never supplied.**
`Ecto.ParameterizedType.init/1` receives `:schema` and `:field` alongside the
field's options. The generated type resolves, once, at field-declaration time:

- `"table"` from `schema.__schema__(:source)`
- `"column"` from the `:field` option

and bakes both into its params. A host cannot forget them, cannot misspell
them, and cannot make two fields in one table share a context by accident. If
either is unavailable (the type used outside a schema, e.g. in a bare
`Ecto.Query` cast), `init/1` raises: a context-less encrypt is never performed.

Schema prefixes are deliberately **not** part of the context. A prefix is a
deployment-time placement decision and can differ between environments for the
same logical table; binding it would make ciphertext un-restorable into a
differently-prefixed database. Tenancy is carried by the tenant key
(decision 5), which is the property that actually needs binding.

**5. Tenant context is resolved from an explicit process scope, and its
absence is an error.** This is the record's hard decision, so it is stated in
parts.

**5a.** The default strategy is `tenant: :scope`. The type reads the current
tenant from a process-scoped store that the host sets explicitly at the edge of
a unit of work:

```elixir
Encryptor.Ecto.Tenant.put(tenant_id)
```

`Encryptor.Ecto.Tenant` is a thin, documented wrapper over the process
dictionary - the same mechanism `Logger.metadata/1` and `Ecto.Repo`'s dynamic
repo use, chosen for the same reason: it is the only channel that reaches an
arbitrary callee without threading a parameter through every intervening
signature, and Ecto's type callbacks run in the caller's process.

**5b.** Process scope does not propagate, and this record does not pretend it
does. A `Task`, a `Task.Supervisor` child, an Oban worker, a GenServer
`handle_call` doing the write on someone else's behalf - all start with an
empty scope. The host propagates explicitly:

```elixir
tenant = Encryptor.Ecto.Tenant.fetch!()
Task.async(fn -> Encryptor.Ecto.Tenant.put(tenant); do_work() end)
```

`Encryptor.Ecto.Tenant.wrap/2` ships as sugar for exactly that, and the
package's documentation names every boundary a host is expected to wrap. Making
this visible is the point: an invisible propagation mechanism is one whose
gaps are also invisible.

**5c.** **A dump with no tenant in scope raises.** Not a default tenant, not a
`nil` tenant, not a global key, not a log line. `Encryptor.Ecto.MissingTenantError`
names the table and column and says which scope call was missing. The failure
mode this forbids - a row written under the wrong key because a background job
forgot - is unrecoverable in a way an exception on the first test run is not.

**5d.** Loads raise the same way, deliberately. It would be possible to load
with whatever context the row implies and let the AAD check fail, but a raise
with a legible message beats an authentication failure that reads like data
corruption. Where the tenant *is* in scope but wrong, the AAD check is the
backstop and the read fails authentication (upstream's decrypt error arm) -
which is the anti-substitution property working as designed, and is reported as
such rather than as a missing-scope error.

**5e.** `tenant: :none` declares a field global. It is written at the field, in
the schema, where a reviewer sees it next to the column it applies to. Fields
declared `:none` omit the tenant key from their context entirely, and their
ciphertexts are therefore *not* crypto-shreddable with a tenant key - a
consequence the documentation states plainly at the option.

**5f.** `tenant: MyApp.SomeResolver` escapes the whole mechanism. The
`Encryptor.Ecto.TenantContext` behaviour is one callback,
`resolve(operation, params) :: {:ok, String.t()} | :none | {:error, term}`,
where `operation` is `:dump` or `:load`. A host that already has an ambient
request context (a Plug-assigned value in a process-scoped struct, a dynamic
repo name it can map, a sharded connection) implements this and never touches
`Encryptor.Ecto.Tenant`. The default `:scope` strategy is itself an
implementation of this behaviour, and is not privileged.

**Alternatives considered, and why they lost:**

- *Read the tenant off the struct or changeset.* The obvious answer, and it is
  structurally impossible: `Ecto.Type` callbacks receive the value and the type
  params, never the parent struct. Making it possible would mean abandoning
  `Ecto.Type` for changeset-level hooks, which loses the property the whole
  package is for - that reads and writes through any path (`Repo.insert_all`,
  `Repo.update_all`, a raw query cast, a preload) are encrypted without the
  call site's cooperation.
- *Pass context per call through Ecto options or the query prefix.* Ecto does
  not thread arbitrary caller options into type callbacks; `:prefix` is the
  only ambient value that reaches the adapter, it means something else
  (decision 4), and it does not reach `dump/3` as data. Building on it would be
  building on a coincidence.
- *A vault module per tenant.* Restores static resolution - and requires a
  module per tenant, generated at runtime, in a host that provisions tenants
  from a web form. Non-starter.
- *A per-tenant dynamic repo.* Works for hosts already sharding by repo, and
  reaches nothing else; it also cannot express two tenants inside one
  transaction. Available as a `:tenant` resolver module (5f), not as the
  default.
- *Fall back to a configured default tenant when scope is empty.* Rejected
  hardest of the five. It converts a loud, early, once-per-codebase failure
  into a silent, durable, per-row one.

**6. Failures raise; they do not return `:error`.** `Ecto.Type`'s `:error` arm
means "this value failed to cast", and it surfaces as a validation-shaped
`Ecto.ChangeError` with no room for a reason. An encrypt failure is an
infrastructure failure and a decrypt failure is an *integrity event*; neither
is a validation error and neither should be catchable by a changeset that then
proceeds. The types therefore raise:

| Condition | Exception |
|---|---|
| No tenant in scope, strategy `:scope` | `Encryptor.Ecto.MissingTenantError` |
| Vault returns an encrypt error | `Encryptor.Ecto.EncryptError` |
| Vault returns a decrypt error (including AAD mismatch) | `Encryptor.Ecto.DecryptError` |
| Stored bytes are not a well-formed message | `Encryptor.Ecto.DecryptError` |
| Serializer fails on a `Map` value | `Encryptor.Ecto.SerializationError` |

`cast/2` keeps the ordinary `:error` arm, because a cast failure genuinely *is*
a validation error: a non-binary handed to `Binary`, a non-map handed to `Map`.
Cast never encrypts.

Every exception carries the table, column, context keys (not values beyond the
tenant identifier), and the upstream reason. **No exception message, log line,
or `Exception.message/1` ever includes plaintext, ciphertext bytes, or key
material** - including in the `Inspect` implementation of the exception struct.
That prohibition is part of this decision, not a code-review preference.

**7. `nil` is `NULL`; empty is not `nil`.** `dump(nil)` is `{:ok, nil}` and
`load(nil)` is `{:ok, nil}` - a `NULL` column stays `NULL` and no encryption
happens. Presence is already visible to anyone with the database (the column is
`NULL` or it is not), and encrypting `nil` into bytes would break every
`is_nil` query and `null: false` constraint a host has.

Empty values are *not* `nil` and *are* encrypted: `""` round-trips as `""`,
`%{}` round-trips as `%{}`. The distinction between "no value" and "empty
value" is the host's to make and this layer preserves it exactly.

**8. `Map` serializes through JSON, and loads with string keys.** The default
serializer is `Jason`; `:json` accepts any module exporting `encode!/1` and
`decode!/1`. A loaded map has **string keys**, always, matching what
`:map`-typed Ecto columns already do. Atom keys are not offered: they cannot
round-trip safely (`String.to_existing_atom/1` fails on a key whose atom the
loading node has not yet created) and they are an unbounded-atom hazard driven
by stored data.

`:erlang.term_to_binary/1` was considered and rejected: it makes the payload a
deserialization surface, ties stored bytes to the BEAM, and would let a
successfully-authenticated-but-hostile payload construct arbitrary terms.
Encrypted bytes are still bytes that may have come from a restore of somebody
else's backup; the deserializer stays boring on purpose.

A host wanting struct fidelity uses an embedded schema over
`Encryptor.Ecto.Map`, not a smarter serializer.

**9. `equal?/3` compares plaintext, and `embed_as/2` is `:self`.** Ciphertext is
non-deterministic - the same plaintext encrypts to different bytes every time -
so any comparison over dumped values marks every field changed on every write.
Ecto compares cast (plaintext) values, which is the correct behaviour here, and
the types implement `equal?/3` over plaintext to keep it that way should a
future Ecto path compare dumped values.

**10. Encrypted columns are not queryable, and this package will not pretend
otherwise.** No equality lookup, no `LIKE`, no ordering, no unique index, no
`ON CONFLICT` target. There is no "searchable" option and there will not be
one. Exact-match lookup is served by the forthcoming blind-index record
(ece-azn), which is a separate column with its own key derivation and its
own explicitly documented leakage. Attempting a query against an encrypted
field is a host bug this package cannot detect; the documentation says so at the top.

**11. The stored bytes are upstream's format, stored verbatim.** This layer
adds no envelope, no version prefix, no magic bytes. Whatever the vault returns
goes into the column unchanged, and whatever is in the column goes back to the
vault unchanged. Format versioning, algorithm agility, and key rotation are the
`encryptor` package's records; a migration between formats is a data migration
(the ece-56a record), not a type-level compatibility shim. Two consequences worth
naming: this package has no opinion on ciphertext size, and a host cannot tell
from the column alone which key version wrote a row - the upstream message
header carries that.

## Upstream API assumptions

These are assumptions about the `encryptor` package, whose founding records are
being drafted in parallel with this one. **Each is a review item for
acceptance**, not a settled fact; if any is wrong, the affected decision here
changes mechanically and the shape survives.

| # | Assumed | Used by |
|---|---|---|
| A1 | A vault module exports `encrypt(plaintext, context)` and `decrypt(message, context)` returning `{:ok, binary}` / `{:error, reason}` | 1, 6 |
| A2 | `context` is a flat map of string keys to string values | 3, 4, 5 |
| A3 | The canonical context keys include `"tenant_id"`, `"table"`, `"column"` | 4, 5 |
| A4 | Required-vs-advisory context enforcement lives upstream (a required-context CMM), so this layer *supplies* keys and never *enforces* them | 4, 5d |
| A5 | Decrypt reports AAD mismatch as a distinguishable error reason, not a generic failure | 5d, 6 |
| A6 | The vault message is self-describing (key version, algorithm) so the column needs no framing | 11 |
| A7 | Tenant key material is addressed by an opaque tenant identifier the host already has as a string | 5 |

## The contract as typespecs

```elixir
defmodule Encryptor.Ecto.TenantContext do
  @moduledoc "Resolves the tenant identifier for an encrypted field."

  @type operation :: :dump | :load
  @type params :: %{
          required(:vault) => module(),
          required(:table) => String.t(),
          required(:column) => String.t(),
          optional(:opts) => keyword()
        }

  @callback resolve(operation(), params()) ::
              {:ok, String.t()} | :none | {:error, term()}
end

defmodule Encryptor.Ecto.Tenant do
  @spec put(String.t()) :: :ok
  @spec get() :: {:ok, String.t()} | :error
  @spec fetch!() :: String.t()
  @spec clear() :: :ok
  @spec wrap(String.t(), (-> result)) :: result when result: var
end

# The shape every generated type module satisfies.
defmodule Encryptor.Ecto.Binary do
  @type opts :: [
          vault: module(),
          tenant: :scope | :none | module(),
          context: %{optional(String.t()) => String.t()}
        ]

  @spec __using__(opts()) :: Macro.t()
end

# Generated module (behaviour: Ecto.ParameterizedType)
@spec init(keyword()) :: params :: map()
@spec type(params :: map()) :: :binary
@spec cast(term(), params :: map()) :: {:ok, term()} | :error
@spec dump(term(), function(), params :: map()) :: {:ok, binary() | nil}
@spec load(binary() | nil, function(), params :: map()) :: {:ok, term()}
@spec equal?(term(), term(), params :: map()) :: boolean()
@spec embed_as(atom(), params :: map()) :: :self
```

`dump/3` and `load/3` have no `:error` arm in their spec on purpose: per
decision 6 the failure paths raise.

## Worked example: a host migrating off cloak_ecto

Before - a multi-tenant host app, single global key, `cloak_ecto`:

```elixir
defmodule MyApp.Encrypted.Binary do
  use Cloak.Ecto.Binary, vault: MyApp.Vault
end

defmodule MyApp.Accounts.Customer do
  use Ecto.Schema

  schema "customers" do
    field :account_id, :binary_id
    field :tax_id, MyApp.Encrypted.Binary
    field :notes, MyApp.Encrypted.String
    field :profile, MyApp.Encrypted.Map
  end
end
```

After - the type modules change, the schema does not:

```elixir
defmodule MyApp.Encrypted.Binary do
  use Encryptor.Ecto.Binary, vault: MyApp.Vault
end

defmodule MyApp.Encrypted.String do
  use Encryptor.Ecto.String, vault: MyApp.Vault
end

defmodule MyApp.Encrypted.Map do
  use Encryptor.Ecto.Map, vault: MyApp.Vault
end
```

The schema above is unchanged, byte for byte. What the host adds is the scope
call at its edges - one plug, and one wrap per background boundary:

```elixir
defmodule MyAppWeb.Plugs.TenantScope do
  def call(%{assigns: %{current_account: account}} = conn, _opts) do
    Encryptor.Ecto.Tenant.put(account.id)
    conn
  end
end

defmodule MyApp.Workers.Reindex do
  use Oban.Worker

  def perform(%Oban.Job{args: %{"account_id" => account_id}}) do
    Encryptor.Ecto.Tenant.wrap(account_id, fn ->
      MyApp.Accounts.reindex()
    end)
  end
end
```

And what it gets, without changing a call site:

```elixir
# In request scope for account "acct_A".
MyApp.Repo.insert!(%Customer{account_id: "acct_A", tax_id: "123456789"})
# context: %{"tenant_id" => "acct_A", "table" => "customers", "column" => "tax_id"}

# The same bytes, read back in account "acct_B"'s scope, do not decrypt.
# ** (Encryptor.Ecto.DecryptError) customers.tax_id: encryption context
#    mismatch (tenant_id) - the message was not written for this context

# A background job that forgot to wrap fails on the first write, not the
# thousandth read.
# ** (Encryptor.Ecto.MissingTenantError) customers.tax_id: no tenant in scope;
#    call Encryptor.Ecto.Tenant.put/1 or wrap/2 at this boundary, or declare
#    the field with `tenant: :none`

# A genuinely global field says so where the reviewer will see it.
defmodule MyApp.Encrypted.GlobalBinary do
  use Encryptor.Ecto.Binary, vault: MyApp.Vault, tenant: :none
end
```

The data migration from cloak-format to encryptor-format bytes is
the ece-56a record's subject; it is a batched decrypt-with-cloak / encrypt-with-this
pass, and both libraries sit in the tree while it runs.

## Consequences

**The migration really is a two-line swap, for the type modules.** Schemas,
queries, and call sites are untouched. What is *not* free is the scope
discipline (decision 5b): a host adopting this package audits its boundaries
once, and that audit is the actual cost of adoption. Naming that cost honestly
here is better than discovering it in production.

**Every encrypted write is anti-substitution-protected by construction.** A
host cannot opt out of the table/column context, cannot get it wrong, and
cannot get the tenant silently wrong. That is a stronger default than any
cloak-based deployment has today, and it is the reason the option set stays
closed (decision 3): every option that could weaken the context is one nobody
gets.

**Process-dictionary scope is a real limitation, honestly bounded.** It does
not cross processes, it is invisible in a stack trace, and it can be set and
then not cleared in a pooled process - so `wrap/2` restores the prior value and
the plug sets rather than appends. The escape hatch (5f) exists because some
hosts have a better ambient channel than this package can assume.

**Fail-closed means new failure modes in tests.** Hosts will hit
`MissingTenantError` in test setup, factories, and seeds that never had to think
about tenancy. That is the mechanism working; the documentation ships a test-
support helper that scopes a whole test case.

**No queries, no indexes, ever, on these columns.** This is the single largest
behavioural difference from an unencrypted column and it constrains schema
design upstream of this package. The ece-azn record covers exact-match; nothing
covers ranges or ordering, and this record commits to *not* inventing anything
that appears to.

**Two things are deferred, not decided.** The remaining `cloak_ecto` type
wrappers (decision 1) are an implementation bead. And per-field key derivation
- distinct keys per column rather than per tenant - is out of scope here; the
column already rides the AAD, which gets the anti-substitution property without
a second key hierarchy.
