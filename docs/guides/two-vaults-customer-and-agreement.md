# Two vaults: a customer scope and an agreement scope

This guide is for a SaaS host that holds two kinds of data with two
different lifetimes. Its own platform data - a customer's account, the
credentials the platform keeps on the customer's behalf - lives as long as
the customer does. Data a customer shares under a data agreement lives only
as long as the agreement does: when the agreement ends, its deletion
obligation says that data must be destroyed, and the customer's account and
every other agreement must keep working.

The answer is two scoped vaults. One vault's scope is the customer, the
other's is the agreement id, and ending an agreement is a shred of that one
agreement's key. The guide builds both, with a schema for each, the scope
resolver each one needs, and the shred.

The worked host is a catalog service for libraries. Each customer is a
library, whose account holds the token the service uses to call that
library's catalog. A library can also share its loan records under a data
agreement - a reading study, a holds pilot - and each agreement has its own
end date and its own deletion obligation. Everything below compiles and runs:
`test/encryptor/ecto/two_vaults_guide_test.exs` runs this guide's code
against real vaults, a real key store and real tables.

It assumes a scoped vault already reading from the key store (the
`## Configuring it` section of `Encryptor.Ecto.KeyStore`) and the wrapped-key
table that `mix encryptor.ecto.gen.key_store_migration` creates.

## Step 1. Decide that there are two scopes

`encryptor`'s *Choosing the scope* guide gives the rule in one sentence: a
scope is whatever must be able to go away on its own. A library must be able
to go away on its own, and so must each agreement - an agreement can end
while the library stays. Those are two boundaries, and the same guide gives
the answer for that case: two vaults with two namespaces, not a composite
selector. A selector like `"lib_branch_north/agr_2026_reading_study"` is one
key that two different procedures both want to destroy.

So:

| Vault | Scope | Holds |
|---|---|---|
| customer | the customer id | platform data and credentials: the account, the catalog token |
| agreement | the agreement id | data licensed under that agreement: the shared loan records |

A value belongs to exactly one of them. A licensed row may *carry* the
customer id as a plaintext column, but its encrypted fields are under the
agreement's key and nothing else.

## Step 2. Create the tables

The customer vault's keys go in the default wrapped-key table. The agreement
vault's keys go in a table of their own, which the same generator writes:

```sh
mix encryptor.ecto.gen.key_store_migration
mix encryptor.ecto.gen.key_store_migration --table agreement_keys
```

Two tables rather than one, because the key store finds a scope's rows by
`tenant_ref` alone - the keyed reference `Encryptor.Envelope.scope_ref/2`
derives from the selector - and both vaults derive it under the same
reference subkey. In one table a customer and an agreement that happened to
share an identifier would share key rows, and a shred of one would destroy
the other. In two tables they cannot meet.

The data tables are ordinary, with a `:binary` column for each encrypted
field. The scope columns - `customer_id`, `agreement_id` - stay plaintext:
they are how a row finds its key, and an encrypted column is never
queryable.

## Step 3. Configure one root vault and two scoped vaults

Both key tables hold wrappings produced by one root vault, so there is one
root key and one module that derives what the vaults need from it:

```elixir
defmodule Library.Keys do
  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Envelope
  alias Library.Repo

  @agreement_table "agreement_keys"

  def root_key do
    :library
    |> Application.fetch_env!(:root_key_base64)
    |> Base.decode64!()
  end

  def wrapping_subkey, do: Envelope.root_subkey(root_key(), "root-wrap")
  def reference_subkey, do: Envelope.root_subkey(root_key(), "tenant-ref")
  def agreement_table, do: @agreement_table

  def provision(:customer, customer_id),
    do: provision(KeyStore.default_table(), "library-customer", customer_id)

  def provision(:agreement, agreement_id),
    do: provision(@agreement_table, "library-agreement", agreement_id)

  defp provision(table, namespace, selector) do
    with {:ok, wrapped} <-
           Envelope.provision(Library.RootVault, selector,
             reference_subkey: reference_subkey(),
             namespace: namespace,
             version: 1
           ) do
      {1, _rows} =
        Repo.insert_all(table, [
          [
            tenant_ref: wrapped.scope_ref,
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

  def shred_agreement(agreement_id, opts \\ []) do
    KeyStore.shred(Library.AgreementVault, agreement_id, Keyword.put(opts, :version, :all))
  end
end
```

`provision/2` is yours to call: the key store mints nothing, so a new library
or a newly signed agreement gets its first key version when your onboarding
code says so. The wrapping comes back keyed `scope_ref`, and the insert
writes it into the `tenant_ref` column: the column keeps the name it had
before the scope rename, because it exists in every adopter's database
(ADR-0006 decision 3). Each vault's keys carry their own namespace
(`"library-customer"`, `"library-agreement"`), which is the "two namespaces"
half of Step 1. `shred_agreement/2` is Step 6.

The root vault is a single-key vault with a `Static` provider and
`cache: false`:

```elixir
defmodule Library.RootVault do
  use Encryptor.Vault, otp_app: :library, context_profile: :single, cache: false

  alias Library.Keys

  def init(config) do
    {:ok,
     Keyword.put(
       config,
       :provider,
       {Encryptor.Provider.Static,
        key: Keys.wrapping_subkey(), namespace: "library-root", name: "root/v1"}
     )}
  end
end
```

The two scoped vaults differ in one option. The customer vault reads the
default table:

```elixir
defmodule Library.CustomerVault do
  use Encryptor.Vault,
    otp_app: :library,
    context_profile: :scoped,
    required_context: ["table", "column"],
    cache: [max_age: 300]

  alias Library.Keys

  def init(config) do
    {:ok,
     Keyword.merge(config,
       provider:
         {Encryptor.Ecto.KeyStore,
          repo: Library.Repo, root_vault: Library.RootVault, reference_subkey: Keys.reference_subkey()},
       reference_subkey: Keys.reference_subkey()
     )}
  end
end
```

The agreement vault names its own table with the key store's `:table`
option:

```elixir
defmodule Library.AgreementVault do
  use Encryptor.Vault,
    otp_app: :library,
    context_profile: :scoped,
    required_context: ["table", "column"],
    cache: [max_age: 300]

  alias Library.Keys

  def init(config) do
    {:ok,
     Keyword.merge(config,
       provider:
         {Encryptor.Ecto.KeyStore,
          repo: Library.Repo,
          root_vault: Library.RootVault,
          reference_subkey: Keys.reference_subkey(),
          table: Keys.agreement_table()},
       reference_subkey: Keys.reference_subkey()
     )}
  end
end
```

Start all three in your supervision tree after the repo. `max_age` is in
seconds, and it matters in Step 6: it is how long the shred waits, by
default, for a running node's cached key materials to expire.

## Step 4. The customer scope comes from the process

The customer vault's fields use the default resolver, `scope: :process`,
which reads the scope the calling process set with `Encryptor.Ecto.Scope`:

```elixir
defmodule Library.Encrypted.CustomerBinary do
  use Encryptor.Ecto.Binary, vault: Library.CustomerVault
end
```

```elixir
defmodule Library.Account do
  use Ecto.Schema

  schema "library_accounts" do
    field :customer_id, :string
    field :catalog_api_token, Library.Encrypted.CustomerBinary
  end
end
```

Set the scope where a unit of work starts - in a `Plug` once the request's
library is known, in an Oban worker's `perform/1` - and read and write as
usual:

```elixir
Encryptor.Ecto.Scope.wrap(customer_id, fn ->
  Library.Repo.insert!(%Library.Account{customer_id: customer_id, catalog_api_token: token})
end)
```

`Encryptor.Ecto.Scope` lists the boundaries a host is expected to wrap. A
write from a process that never set a scope raises
`Encryptor.Ecto.MissingScopeError`; a row read under another library's scope
raises `Encryptor.Ecto.DecryptError`.

## Step 5. The agreement scope comes from the row

The agreement vault cannot use `scope: :process` as well. The process holds
one scope, and a request that reads a library's account and writes a loan
record under one of its agreements needs two at once.

Nor can a resolver read the agreement id off the row itself. An `Ecto.Type`
callback receives the value and the type's params, never the struct it
belongs to (ADR-0001 decision 5, the first of its "Alternatives
considered"), and `c:Encryptor.Ecto.ScopeContext.resolve/2` is handed the
field's declared vault, table and column and nothing about the row. So the
row's agreement id is put where the resolver can read it, by the code that
has the row in hand - the same arrangement `Encryptor.Ecto.Migrator.RowScope`
makes when a migration plan says `scope_from :some_column`.

The resolver keeps the agreement id in a process key of its own, so it never
touches the customer scope:

```elixir
defmodule Library.AgreementScope do
  @behaviour Encryptor.Ecto.ScopeContext

  @key {__MODULE__, :agreement_id}

  def with_agreement(agreement_id, fun) when is_binary(agreement_id) and is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, agreement_id)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @impl Encryptor.Ecto.ScopeContext
  def resolve(_operation, _params) do
    case Process.get(@key) do
      agreement_id when is_binary(agreement_id) -> {:ok, agreement_id}
      nil -> {:error, :no_agreement_in_scope}
    end
  end
end
```

`with_agreement/2` restores whatever was set before it, so it nests, and an
exception inside it cannot leave a stale agreement behind for the next unit
of work. `resolve/2` answers `{:error, _}` when nothing is set, never a
default agreement: the type then raises `Encryptor.Ecto.MissingScopeError`
instead of writing a row under a key that is not its own.

The type module names the resolver, and the schema names the type:

```elixir
defmodule Library.Encrypted.AgreementString do
  use Encryptor.Ecto.String,
    vault: Library.AgreementVault,
    scope: Library.AgreementScope
end
```

```elixir
defmodule Library.SharedLoan do
  use Ecto.Schema

  schema "shared_loans" do
    field :customer_id, :string
    field :agreement_id, :string
    field :patron_email, Library.Encrypted.AgreementString
  end
end
```

Every read and write of a licensed row goes through functions that take the
agreement id from the row, or from the query that selects the rows:

```elixir
defmodule Library.Loans do
  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Library.AgreementScope
  alias Library.Repo
  alias Library.SharedLoan

  def record(attrs) do
    %SharedLoan{}
    |> Changeset.cast(attrs, [:customer_id, :agreement_id, :patron_email])
    |> Changeset.validate_required([:customer_id, :agreement_id])
    |> insert_under_agreement()
  end

  defp insert_under_agreement(%Changeset{valid?: false} = changeset), do: {:error, changeset}

  defp insert_under_agreement(changeset) do
    agreement_id = Changeset.fetch_field!(changeset, :agreement_id)
    AgreementScope.with_agreement(agreement_id, fn -> Repo.insert(changeset) end)
  end

  def list(agreement_id) do
    AgreementScope.with_agreement(agreement_id, fn ->
      Repo.all(from(l in SharedLoan, where: l.agreement_id == ^agreement_id))
    end)
  end

  def forget(agreement_id) do
    {count, _rows} =
      Repo.delete_all(from(l in SharedLoan, where: l.agreement_id == ^agreement_id))

    {:ok, count}
  end
end
```

`record/1` reads the agreement id off the changeset it is about to insert,
and a changeset without one is refused by the validation before anything is
encrypted. `list/1` filters to the agreement it scopes, and the filter is not
optional: a query whose rows span agreements loads every row under the one
agreement in scope, and the first row of another agreement raises
`Encryptor.Ecto.DecryptError`. The scope is one value per load, so a
read of licensed rows is a read of one agreement's rows.

## Step 6. Shred one agreement when it ends

An agreement's deletion obligation is met by destroying that agreement's
key. `encryptor`'s ADR-0005 makes a shred the delete of a scope's wrapping
rows ("A shred deletes the row"), and its runbook P3 is the procedure.
`Encryptor.Ecto.KeyStore.shred/3` performs it against the key table a
running vault reads: with `version: :all` it deletes every version of the
scope in one locked transaction, waits out the vault's cache `max_age`, and
returns an `Encryptor.Ecto.KeyStore.Shred` record of what it deleted.
`Library.Keys.shred_agreement/2` above is that call for the agreement vault.
Do not replace it with a hand-written `delete_all`: that takes no lock,
waits for no drain and leaves no record.

1. **Record the decision.** P3 requires a recorded, human decision before a
   shred, and says a shred is never automated and never a cascade from
   another delete. The agreement's end is the decision; write down which
   agreement and when.
2. **Shred the agreement's key.** `Library.Keys.shred_agreement(agreement_id)`
   returns `{:ok, %Encryptor.Ecto.KeyStore.Shred{}}`. Its `versions` lists
   every version deleted - a key provisioned as above has one, and a rotated
   one has more - and its `deleted_at` and `drained_at` belong in the change
   record beside the decision.
3. **Let the drain finish.** By default the call returns only once the
   agreement vault's `max_age` - 300 seconds with the vaults above - has
   passed since the delete, which is P3's cache drain. A host that restarts
   the agreement vault on every node instead passes `drain: :skip` and
   restarts; the record's `drained_at` still says when waiting would have
   finished. With `encryptor` 0.5.0 a read of the shredded agreement already
   fails when the delete commits, because the vault asks the key store before
   it consults its cache; the drain stays because P3 makes it a step
   (this package's ADR-0007).
4. **Delete the licensed rows.** `Library.Loans.forget/1`. After step 3 they
   are unreadable bytes, but every message header still carries the
   agreement's permanent pseudonym, the `tenant_ref`. Where the fact of the
   agreement is itself personal data, this step is as mandatory as the
   shred.

After step 3, the application sees:

| Call | Answer |
|---|---|
| `Library.Loans.list/1` for the shredded agreement | raises `Encryptor.Ecto.DecryptError`, `reason: {:unknown_key, agreement_id}` |
| `Library.Loans.record/1` for the shredded agreement | raises `Encryptor.Ecto.EncryptError`, `reason: {:unknown_key, agreement_id}` |
| `Library.Loans.list/1` for any other agreement | the rows, as before |
| a read of the library's `Library.Account` | the token, as before |

`{:unknown_key, agreement_id}` is the answer `encryptor`'s ADR-0005
decision 9 fixes for a scope with no live key: it is distinct from a corrupt
or tampered row, which fails as `:decrypt_failed`.

A shred reaches the primary store only. Backups taken while the key rows
existed, replicas that have not applied the delete, and exports still hold
the wrappings; ADR-0005 states that limit, and a deletion obligation that
covers backups needs a backup retention to match.

## What each vault's shred means

| Shred | Destroys | Leaves readable |
|---|---|---|
| one agreement | that agreement's key rows in `agreement_keys`, so every licensed row written under it | the library's account and credentials, and every other agreement |
| one customer | that library's key rows in the default table, so its account data and credentials | every agreement's licensed rows, which are under the agreement keys |

The second row is the one to plan for. Offboarding a library is not one
shred: the customer shred reaches only the customer vault. Each agreement
the library held that must end with it is its own shred, run by the same
procedure - which is what P3's "never a cascade" asks for, and what the two
boundaries of Step 1 were chosen to allow.

## What this guide checked

`test/encryptor/ecto/two_vaults_guide_test.exs` compiles every module block
above, with the repo and the `Library` prefix swapped for the test suite's
own, and fails when a block and the tested code differ. It then runs Steps 3
to 6: each vault's keys in its own table, the customer round trip and its
refusals, a loan written and read under the agreement on its row, the
refusal of a read that spans agreements and of a write with no agreement in
scope, and a shred of one agreement with the answers in the table above.
