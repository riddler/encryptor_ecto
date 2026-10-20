# How to keep a long-lived scope and a short-lived scope in two vaults

This guide is for a host that holds two kinds of data with two different
lifetimes. Owner data - the records the host keeps for an owner - lives as
long as the owner does. Grant data - records written under a grant the owner
opens - lives only as long as the grant does: when the grant ends, its data
must be destroyed, and the owner's own data and every other grant must keep
working.

The answer is two scoped vaults. One vault's scope is the owner, the other's
is the grant id, and ending a grant is a shred of that one grant's key. The
guide builds both, with a schema for each, the scope resolver each one needs,
and the shred.

The worked host has owners and grants. Each owner has one record holding a
secret token. An owner can also open grants, and each grant has its own end
date and its own destruction obligation for the records written under it.
Everything below compiles and runs:
`test/encryptor/ecto/two_vaults_guide_test.exs` runs this guide's code
against real vaults, a real key store and real tables.

It assumes a scoped vault already reading from the key store (the
`## Configuring it` section of `Encryptor.Ecto.KeyStore`) and the wrapped-key
table that `mix encryptor.ecto.gen.key_store_migration` creates.

## Step 1. Decide that there are two scopes

`encryptor`'s *Choosing the scope* guide gives the rule in one sentence: a
scope is whatever must be able to go away on its own. An owner must be able
to go away on its own, and so must each grant - a grant can end
while the owner stays. Those are two boundaries, and the same guide gives
the answer for that case: two vaults with two namespaces, not a composite
selector. A selector like `"owner-1/grant-1"` is one
key that two different procedures both want to destroy.

So:

| Vault | Scope | Holds |
|---|---|---|
| owner | the owner id | the owner's own data: the record holding the secret token |
| grant | the grant id | data written under that grant: the grant records |

A value belongs to exactly one of them. A grant row may *carry* the
owner id as a plaintext column, but its encrypted fields are under the
grant's key and nothing else.

## Step 2. Create the tables

The owner vault's keys go in the default wrapped-key table. The grant
vault's keys go in a table of their own, which the same generator writes:

```sh
mix encryptor.ecto.gen.key_store_migration
mix encryptor.ecto.gen.key_store_migration --table grant_keys
```

Two tables rather than one, because the key store finds a scope's rows by
`scope_ref` alone - the keyed reference `Encryptor.Envelope.scope_ref/2`
derives from the selector - and both vaults derive it under the same
reference subkey. In one table an owner and a grant that happened to
share an identifier would share key rows, and a shred of one would destroy
the other. In two tables they cannot meet.

The data tables are ordinary, with a `:binary` column for each encrypted
field. The scope columns - `owner_id`, `grant_id` - stay plaintext:
they are how a row finds its key, and an encrypted column is never
queryable.

## Step 3. Configure one root vault and two scoped vaults

Both key tables hold wrappings produced by one root vault, so there is one
root key and one module that derives what the vaults need from it:

```elixir
defmodule MyApp.Keys do
  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Envelope
  alias MyApp.Repo

  @grant_table "grant_keys"

  def root_key do
    :my_app
    |> Application.fetch_env!(:root_key_base64)
    |> Base.decode64!()
  end

  def wrapping_subkey, do: Envelope.root_subkey(root_key(), "root-wrap")
  def reference_subkey, do: Envelope.root_subkey(root_key(), "scope-ref")
  def grant_table, do: @grant_table

  def provision(:owner, owner_id),
    do: provision(KeyStore.default_table(), "my-app-owner", owner_id)

  def provision(:grant, grant_id),
    do: provision(@grant_table, "my-app-grant", grant_id)

  defp provision(table, namespace, selector) do
    with {:ok, wrapped} <-
           Envelope.provision(MyApp.RootVault, selector,
             reference_subkey: reference_subkey(),
             namespace: namespace,
             version: 1
           ) do
      {1, _rows} =
        Repo.insert_all(table, [
          [
            scope_ref: wrapped.scope_ref,
            version: wrapped.version,
            namespace: wrapped.namespace,
            name: wrapped.name,
            bits: wrapped.bits,
            wrapped: wrapped.wrapped,
            wrapping_shape: "engine_message"
          ]
        ])

      :ok
    end
  end

  def shred_grant(grant_id, opts \\ []) do
    KeyStore.shred(MyApp.GrantVault, grant_id, Keyword.put(opts, :version, :all))
  end
end
```

`provision/2` is yours to call: the key store mints nothing, so a new owner
or a newly opened grant gets its first key version when your provisioning
code says so. The wrapping comes back keyed `scope_ref`, and the insert
writes it into the column of the same name (ADR-0006 Amendment A). Each
vault's keys carry their own namespace
(`"my-app-owner"`, `"my-app-grant"`), which is the "two namespaces"
half of Step 1. `shred_grant/2` is Step 6.

The root vault is a single-key vault with a `Static` provider and
`cache: false`:

```elixir
defmodule MyApp.RootVault do
  use Encryptor.Vault, otp_app: :my_app, context_profile: :single, cache: false

  alias MyApp.Keys

  def init(config) do
    {:ok,
     Keyword.put(
       config,
       :provider,
       {Encryptor.Provider.Static,
        key: Keys.wrapping_subkey(), namespace: "my-app-root", name: "root/v1"}
     )}
  end
end
```

The two scoped vaults differ in one option. The owner vault reads the
default table:

```elixir
defmodule MyApp.OwnerVault do
  use Encryptor.Vault,
    otp_app: :my_app,
    context_profile: :scoped,
    required_context: ["table", "column"],
    cache: [max_age: 300]

  alias MyApp.Keys

  def init(config) do
    {:ok,
     Keyword.merge(config,
       provider:
         {Encryptor.Ecto.KeyStore,
          repo: MyApp.Repo, root_vault: MyApp.RootVault, reference_subkey: Keys.reference_subkey()},
       reference_subkey: Keys.reference_subkey()
     )}
  end
end
```

The grant vault names its own table with the key store's `:table`
option:

```elixir
defmodule MyApp.GrantVault do
  use Encryptor.Vault,
    otp_app: :my_app,
    context_profile: :scoped,
    required_context: ["table", "column"],
    cache: [max_age: 300]

  alias MyApp.Keys

  def init(config) do
    {:ok,
     Keyword.merge(config,
       provider:
         {Encryptor.Ecto.KeyStore,
          repo: MyApp.Repo,
          root_vault: MyApp.RootVault,
          reference_subkey: Keys.reference_subkey(),
          table: Keys.grant_table()},
       reference_subkey: Keys.reference_subkey()
     )}
  end
end
```

Start all three in your supervision tree after the repo. `max_age` is in
seconds, and it matters in Step 6: it is how long the shred waits, by
default, for a running node's cached key materials to expire.

## Step 4. The owner scope comes from the process

The owner vault's fields use the default resolver, `scope: :process`,
which reads the scope the calling process set with `Encryptor.Ecto.Scope`:

```elixir
defmodule MyApp.Encrypted.OwnerBinary do
  use Encryptor.Ecto.Binary, vault: MyApp.OwnerVault
end
```

```elixir
defmodule MyApp.OwnerRecord do
  use Ecto.Schema

  schema "owner_records" do
    field :owner_id, :string
    field :secret_token, MyApp.Encrypted.OwnerBinary
  end
end
```

Set the scope where a unit of work starts - in a `Plug` once the request's
owner is known, in an Oban worker's `perform/1` - and read and write as
usual:

```elixir
Encryptor.Ecto.Scope.wrap(owner_id, fn ->
  MyApp.Repo.insert!(%MyApp.OwnerRecord{owner_id: owner_id, secret_token: token})
end)
```

`Encryptor.Ecto.Scope` lists the boundaries a host is expected to wrap. A
write from a process that never set a scope raises
`Encryptor.Ecto.MissingScopeError`; a row read under another owner's scope
raises `Encryptor.Ecto.DecryptError`.

## Step 5. The grant scope comes from the row

The grant vault cannot use `scope: :process` as well. The process holds
one scope, and a request that reads an owner's record and writes a grant
record under one of its grants needs two at once.

Nor can a resolver read the grant id off the row itself. An `Ecto.Type`
callback receives the value and the type's params, never the struct it
belongs to (ADR-0001 decision 5, the first of its "Alternatives
considered"), and `c:Encryptor.Ecto.ScopeContext.resolve/2` is handed the
field's declared vault, table and column and nothing about the row. So the
row's grant id is put where the resolver can read it, by the code that
has the row in hand - the same arrangement `Encryptor.Ecto.Migrator.RowScope`
makes when a migration plan says `scope_from :some_column`.

The resolver keeps the grant id in a process key of its own, so it never
touches the owner scope:

```elixir
defmodule MyApp.GrantScope do
  @behaviour Encryptor.Ecto.ScopeContext

  @key {__MODULE__, :grant_id}

  def with_grant(grant_id, fun) when is_binary(grant_id) and is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, grant_id)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @impl Encryptor.Ecto.ScopeContext
  def resolve(_operation, _params) do
    case Process.get(@key) do
      grant_id when is_binary(grant_id) -> {:ok, grant_id}
      nil -> {:error, :no_grant_in_scope}
    end
  end
end
```

`with_grant/2` restores whatever was set before it, so it nests, and an
exception inside it cannot leave a stale grant behind for the next unit
of work. `resolve/2` answers `{:error, _}` when nothing is set, never a
default grant: the type then raises `Encryptor.Ecto.MissingScopeError`
instead of writing a row under a key that is not its own.

The type module names the resolver, and the schema names the type:

```elixir
defmodule MyApp.Encrypted.GrantString do
  use Encryptor.Ecto.String,
    vault: MyApp.GrantVault,
    scope: MyApp.GrantScope
end
```

```elixir
defmodule MyApp.GrantRecord do
  use Ecto.Schema

  schema "grant_records" do
    field :owner_id, :string
    field :grant_id, :string
    field :note, MyApp.Encrypted.GrantString
  end
end
```

Every read and write of a grant row goes through functions that take the
grant id from the row, or from the query that selects the rows:

```elixir
defmodule MyApp.GrantRecords do
  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias MyApp.GrantRecord
  alias MyApp.GrantScope
  alias MyApp.Repo

  def record(attrs) do
    %GrantRecord{}
    |> Changeset.cast(attrs, [:owner_id, :grant_id, :note])
    |> Changeset.validate_required([:owner_id, :grant_id])
    |> insert_under_grant()
  end

  defp insert_under_grant(%Changeset{valid?: false} = changeset), do: {:error, changeset}

  defp insert_under_grant(changeset) do
    grant_id = Changeset.fetch_field!(changeset, :grant_id)
    GrantScope.with_grant(grant_id, fn -> Repo.insert(changeset) end)
  end

  def list(grant_id) do
    GrantScope.with_grant(grant_id, fn ->
      Repo.all(from(l in GrantRecord, where: l.grant_id == ^grant_id))
    end)
  end

  def forget(grant_id) do
    {count, _rows} =
      Repo.delete_all(from(l in GrantRecord, where: l.grant_id == ^grant_id))

    {:ok, count}
  end
end
```

`record/1` reads the grant id off the changeset it is about to insert,
and a changeset without one is refused by the validation before anything is
encrypted. `list/1` filters to the grant it scopes, and the filter is not
optional: a query whose rows spa grants loads every row under the one
grant in scope, and the first row of another grant raises
`Encryptor.Ecto.DecryptError`. The scope is one value per load, so a
read of grant rows is a read of one grant's rows.

## Step 6. Shred one grant when it ends

A grant's deletion obligation is met by destroying that grant's
key. `encryptor`'s ADR-0005 makes a shred the delete of a scope's wrapping
rows ("A shred deletes the row"), and its runbook P3 is the procedure.
`Encryptor.Ecto.KeyStore.shred/3` performs it against the key table a
running vault reads: with `version: :all` it deletes every version of the
scope in one locked transaction, waits out the vault's cache `max_age`, and
returns an `Encryptor.Ecto.KeyStore.Shred` record of what it deleted.
`MyApp.Keys.shred_grant/2` above is that call for the grant vault.
Do not replace it with a hand-written `delete_all`: that takes no lock,
waits for no drain and leaves no record.

1. **Record the decision.** P3 requires a recorded, human decision before a
   shred, and says a shred is never automated and never a cascade from
   another delete. The grant's end is the decision; write down which
   grant and when.
2. **Shred the grant's key.** `MyApp.Keys.shred_grant(grant_id)`
   returns `{:ok, %Encryptor.Ecto.KeyStore.Shred{}}`. Its `versions` lists
   every version deleted - a key provisioned as above has one, and a rotated
   one has more - and its `deleted_at` and `drained_at` belong in the change
   record beside the decision.
3. **Let the drain finish.** By default the call returns only once the
   grant vault's `max_age` - 300 seconds with the vaults above - has
   passed since the delete, which is P3's cache drain. A host that restarts
   the grant vault on every node instead passes `drain: :skip` and
   restarts; the record's `drained_at` still says when waiting would have
   finished. With `encryptor` 0.6.0 a read of the shredded grant already
   fails when the delete commits, because the vault asks the key store before
   it consults its cache; the drain stays because P3 makes it a step
   (this package's ADR-0007).
4. **Delete the grant rows.** `MyApp.GrantRecords.forget/1`. After step 3 they
   are unreadable bytes, but every message header still carries the
   grant's permanent pseudonym, the `scope_ref`. Where the fact of the
   grant is itself personal data, this step is as mandatory as the
   shred.

After step 3, the application sees:

| Call | Answer |
|---|---|
| `MyApp.GrantRecords.list/1` for the shredded grant | raises `Encryptor.Ecto.DecryptError`, `reason: {:unknown_key, grant_id}` |
| `MyApp.GrantRecords.record/1` for the shredded grant | raises `Encryptor.Ecto.EncryptError`, `reason: {:unknown_key, grant_id}` |
| `MyApp.GrantRecords.list/1` for any other grant | the rows, as before |
| a read of the owner's `MyApp.OwnerRecord` | the token, as before |

`{:unknown_key, grant_id}` is the answer `encryptor`'s ADR-0005
decision 9 fixes for a scope with no live key: it is distinct from a corrupt
or tampered row, which fails as `:decrypt_failed`.

A shred reaches the primary store only. Backups taken while the key rows
existed, replicas that have not applied the delete, and exports still hold
the wrappings; ADR-0005 states that limit, and a deletion obligation that
covers backups needs a backup retention to match.

## What each vault's shred means

| Shred | Destroys | Leaves readable |
|---|---|---|
| one grant | that grant's key rows in `grant_keys`, so every grant row written under it | the owner's own data, and every other grant |
| one owner | that owner's key rows in the default table, so its own data | every grant's rows, which are under the grant keys |

The second row is the one to plan for. Removing an owner is not one
shred: the owner shred reaches only the owner vault. Each grant
the owner held that must end with it is its own shred, run by the same
procedure - which is what P3's "never a cascade" asks for, and what the two
boundaries of Step 1 were chosen to allow.

## What this guide checked

`test/encryptor/ecto/two_vaults_guide_test.exs` compiles every module block
above, with the repo and the `MyApp` prefix swapped for the test suite's
own, and fails when a block and the tested code differ. It then runs Steps 3
to 6: each vault's keys in its own table, the owner round trip and its
refusals, a record written and read under the grant on its row, the
refusal of a read that spans grants and of a write with no grant in
scope, and a shred of one grant with the answers in the table above.
