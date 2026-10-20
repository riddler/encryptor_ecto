# How to resolve the scope in jobs and projectors

This guide is for a host whose encrypted writes and reads do not all happen
in the request that knows the scope. A request fans work out to a `Task`, a
request enqueues a background job that runs later, and an event projector
builds a read model from events that belong to many scopes. Each of those
runs in a process that never set a scope, and each needs one.

The worked host has owners, and each owner is a scope: its items' notes
are encrypted under its own key. The request registers items, a background
job reads one item back to send a reminder, and a projector turns item
events into a read model that screens query.
Everything below compiles and runs:
`test/encryptor/ecto/scope_in_jobs_guide_test.exs` runs this guide's code
against a real vault and real tables.

It assumes one scoped vault, `MyApp.Vault`, whose scope is the owner,
configured as in the `## Configuring it` section of
`Encryptor.Ecto.KeyStore`, or as the owner vault of the
[two-vaults guide](two-vaults-long-and-short-lived-scopes.md).

## Step 1. Know where the scope stops

`Encryptor.Ecto.Scope` keeps the scope in the process dictionary of the
process that called `put/1` or `wrap/2`. It is kept there because an
`Ecto.Type` callback runs in the caller's process and receives the value and
the type's params, never the struct, so a process-scoped store is the one
channel that reaches it (ADR-0001 decision 5a).

A process dictionary belongs to one process. A process you start has a
dictionary of its own, and the entries of the process that started it are
not copied into it, so a `Task` starts with no scope even when its caller
had one. A background job is further away still: the enqueuing process
writes the job's arguments to a table, and a queue process - later, perhaps
on another node - reads them back. Only the arguments make that trip.

So the scope does not propagate, and this package does not pretend it does
(ADR-0001 decision 5b). A write or a read of a scoped field from a process
that never set a scope raises `Encryptor.Ecto.MissingScopeError`; it never
falls back to a default scope (decision 5c). Every place work crosses into
another process is a place the host carries the scope across by hand, and
`Encryptor.Ecto.Scope`'s moduledoc lists the boundaries.

The field type used for items reads the process scope, the default:

```elixir
defmodule MyApp.Encrypted.String do
  use Encryptor.Ecto.String, vault: MyApp.Vault
end
```

```elixir
defmodule MyApp.Item do
  use Ecto.Schema

  schema "items" do
    field :owner_id, :string
    field :note, MyApp.Encrypted.String
  end
end
```

## Step 2. Carry the scope into a Task

Read the scope in the caller, before the process boundary, and re-establish
it inside the new process with `Encryptor.Ecto.Scope.wrap/2`:

```elixir
defmodule MyApp.Items do
  alias Encryptor.Ecto.Scope
  alias MyApp.Item
  alias MyApp.Repo

  def register(note) do
    Repo.insert!(%Item{owner_id: Scope.fetch!(), note: note})
  end

  def register_all_async(notes) do
    scope = Scope.fetch!()

    Task.async(fn ->
      Scope.wrap(scope, fn -> Enum.map(notes, &register/1) end)
    end)
  end
end
```

`scope = Scope.fetch!()` runs in the caller, where the scope is set; it
raises there, at the boundary, when the caller has none. The closure carries
the string into the new process, and `wrap/2` sets it for the duration of
the function. `wrap/2` restores what was there before, so the same shape is
safe in a pooled process that runs many units of work.

The same two lines serve `Task.Supervisor.async_nolink/3`,
`Task.async_stream/3`, and a `GenServer` call that writes on someone else's
behalf: read in the caller, pass the string, `wrap/2` on the far side.

## Step 3. Carry the scope into a background job

A job cannot capture a closure. Put the scope in the job's arguments when it
is enqueued, and re-establish it in `perform/1`:

```elixir
defmodule MyApp.Reminders do
  alias Encryptor.Ecto.Scope
  alias MyApp.Item
  alias MyApp.Repo

  def job_args(item_id) do
    %{"owner_id" => Scope.fetch!(), "item_id" => item_id}
  end

  def perform(%{"owner_id" => owner_id, "item_id" => item_id}) do
    Scope.wrap(owner_id, fn ->
      %Item{note: note} = Repo.get!(Item, item_id)
      {:ok, note}
    end)
  end
end
```

`job_args/1` runs in the request, where the scope is set. The arguments are
a map with string keys and JSON values, which is what survives the JSON
round trip a job queue puts arguments through. `perform/1` answers the
address the notice goes to; a real one hands it to the mailer inside the
same `wrap/2`.

With Oban, the worker is one line of delegation, and enqueueing builds the
arguments in the request:

```elixir
defmodule MyApp.Workers.Reminder do
  use Oban.Worker, queue: :reminders

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}), do: MyApp.Reminders.perform(args)
end
```

```elixir
item_id
|> MyApp.Reminders.job_args()
|> MyApp.Workers.Reminder.new()
|> Oban.insert()
```

Keeping the work in a plain module rather than in the worker means the job
can be tested, and run from a console, without a queue. The scope travels as
the owner id, a routing identifier the host already stores in plaintext
columns; it is not a secret, and it is the only thing the job needs to
resolve the key.

## Step 4. Feed a projector's resolver from the event

A projector is different in kind. It writes rows for every owner, one
event after another, in one process: inline, in the process of the command
that emitted the event, and on a rebuild, in a single process replaying the
whole event log. The scope of each write is the owner on the event, not
the scope of the process doing the writing.

A resolver cannot read the owner id off the row it is writing. An
`Ecto.Type` callback never sees the struct (ADR-0001 decision 5, the first
of its "Alternatives considered"), and
`c:Encryptor.Ecto.ScopeContext.resolve/2` is handed the field's declared
vault, table and column and nothing about the row. So the code that holds
the event puts the owner id where the resolver reads it - the arrangement
`Encryptor.Ecto.Migrator.RowScope` makes for a migration plan that says
`scope_from :some_column`.

The resolver keeps the value in a process key of its own, not in
`Encryptor.Ecto.Scope`:

```elixir
defmodule MyApp.ProjectionScope do
  @behaviour Encryptor.Ecto.ScopeContext

  @key {__MODULE__, :owner_id}

  def with_owner(owner_id, fun) when is_binary(owner_id) and is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, owner_id)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @impl Encryptor.Ecto.ScopeContext
  def resolve(_operation, _params) do
    case Process.get(@key) do
      owner_id when is_binary(owner_id) -> {:ok, owner_id}
      nil -> {:error, :no_owner_for_projection}
    end
  end
end
```

A key of its own is what makes the inline case safe. The command's process
has a process scope of its own, and the projector neither reads it nor
overwrites it: a projection written inside a request is under the event's
owner whatever the request's scope is, and the request's scope is
untouched afterwards. `with_owner/2` restores what was there before, in an
`after`, so a raising write cannot leave one event's owner behind for the
next event. `resolve/2` answers `{:error, _}` when nothing is set, and the
type then raises `Encryptor.Ecto.MissingScopeError` rather than writing a
row under a key that is not its own.

The type names the resolver, and the read model names the type:

```elixir
defmodule MyApp.Encrypted.ProjectionString do
  use Encryptor.Ecto.String,
    vault: MyApp.Vault,
    scope: MyApp.ProjectionScope
end
```

```elixir
defmodule MyApp.ItemView do
  use Ecto.Schema

  schema "item_views" do
    field :owner_id, :string
    field :title, :string
    field :note, MyApp.Encrypted.ProjectionString
  end
end
```

The projector hands each event's owner id to the resolver, and the read
side hands it the owner id it filters by:

```elixir
defmodule MyApp.ItemProjector do
  import Ecto.Query, only: [from: 2]

  alias MyApp.ItemView
  alias MyApp.ProjectionScope
  alias MyApp.Repo

  def project(%{"type" => "item_recorded", "owner_id" => owner_id} = event) do
    ProjectionScope.with_owner(owner_id, fn ->
      Repo.insert!(%ItemView{
        owner_id: owner_id,
        title: event["title"],
        note: event["note"]
      })
    end)
  end

  def replay(events), do: Enum.each(events, &project/1)

  def list(owner_id) do
    ProjectionScope.with_owner(owner_id, fn ->
      Repo.all(from(v in ItemView, where: v.owner_id == ^owner_id))
    end)
  end
end
```

`replay/1` walks events from many owners in one process, and each write
is under its own event's owner. `list/1`'s filter is not optional: the
scope is one value per load, so a query whose rows span owners raises
`Encryptor.Ecto.DecryptError` on the first row of another owner.

Both types name the same vault and resolve to the same owner id, so a
projection row is under its owner's key like that owner's item rows,
and a shred of the owner's key reaches both.

## Step 5. Run the projector in a process of its own

A projector usually runs as a handler process of its own: subscribed to the
event log, started under the host's supervision tree, and on whichever node
the tree put it. Nothing that process inherits carries a scope. It never set
one, and a process dictionary crosses neither a process nor a node, so the
scope of the process that emitted an event, or of the process that asks for
a projection row, is not there to read. The handler reads the scope off the
data it is handed instead: off the event for a write, and off the row for a
read-back.

A write needs nothing new. The event carries its owner id, and Step 4's
`project/1` hands it to the resolver. A read-back is the case Step 4 does
not cover: the caller has a projection row's id and nothing else, so no
owner id arrives with the request. The row carries one, in its own
plaintext `owner_id` column. Read that column first, in a query that
selects nothing encrypted and so needs no scope, and then load the row
inside `with_owner/2` under the owner it named:

```elixir
defmodule MyApp.ItemViews do
  import Ecto.Query, only: [from: 2]

  alias MyApp.ItemView
  alias MyApp.ProjectionScope
  alias MyApp.Repo

  def fetch!(id) do
    owner_id = Repo.one!(from(v in ItemView, where: v.id == ^id, select: v.owner_id))

    ProjectionScope.with_owner(owner_id, fn -> Repo.get!(ItemView, id) end)
  end
end
```

The handler takes each event the log delivers as an `{:event, event}`
message and answers read-backs by call:

```elixir
defmodule MyApp.ProjectionHandler do
  use GenServer

  alias MyApp.ItemProjector
  alias MyApp.ItemViews

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)

  def fetch_view(server, id), do: GenServer.call(server, {:fetch_view, id})

  @impl GenServer
  def init(:ok), do: {:ok, nil}

  @impl GenServer
  def handle_info({:event, event}, state) do
    ItemProjector.project(event)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:fetch_view, id}, _from, state) do
    {:reply, ItemViews.fetch!(id), state}
  end
end
```

The handler sets no scope of its own and needs none: each write is under
its event's owner and each read-back under its row's, whichever process
sent the message and whatever that process's scope was. The same code runs
unchanged on every node, because everything it reads the scope from - the
event and the row - is data that crosses the node with it.

## On more than one node

The steps above hold on a cluster as they stand: the scope travels in a
closure, in a job's arguments, on an event and in a row's own column, and
never in a process dictionary. One piece of a vault's state is different in
kind, and that is whether a scope is suspended.

By default a vault keeps its suspended set in a table on the node the vault
runs on: `Encryptor.Vault.Suspension.Store.Ets` is the default
`:suspension_store`. Under that default a suspension is per node.
`Encryptor.Vault.suspend/2` stops the owner on the node it ran on and
nowhere else, a handler process on another node goes on writing and reading
that owner's rows, and the suspension is lost when the vault restarts. A
host running on more than one node would have to suspend on each, and again
after every deploy.

A deployment on more than one node configures its vault with
`Encryptor.Ecto.SuspensionStore`, a store over the host's own repo that
every node reads:

```elixir
config :my_app, MyApp.Vault,
  suspension_store: {Encryptor.Ecto.SuspensionStore, repo: MyApp.Repo},
  suspension_poll_interval: 5_000
```

A suspension then holds on the node that wrote it once the table has it,
and every other node reads the table back on the vault's own poll, every
`:suspension_poll_interval` milliseconds: the interval bounds how long a
node goes on serving an owner after it was suspended elsewhere. The
suspension also survives restarts. The table arrives as migration source the
host reviews and runs, from `mix encryptor.ecto.gen.suspension_store_migration`;
`Encryptor.Ecto.SuspensionStore`'s moduledoc covers its options, its table
and what it answers.

## What this guide checked

`test/encryptor/ecto/scope_in_jobs_guide_test.exs` compiles every module
block above except the Oban worker, with the repo, the vault and the
`MyApp` prefix swapped for the test suite's own, and fails when a block and
the tested code differ. The Oban worker is checked to delegate to
`MyApp.Reminders.perform/1`, since Oban is not a dependency of this
package. The test then shows that a new process starts with no scope, runs
the `Task` of Step 2 and the job of Step 3 in processes of their own - the
job's arguments through a JSON round trip first - and replays interleaved
events of two owners through the projector of Step 4, with no process
scope at all and inline under the other owner's process scope. It starts
the handler of Step 5 as a process of its own, delivers it events of two
owners from a process with no scope and from one under the other owner's
scope, and reads each row back through the handler by its id alone. The
section on more than one node is not run: a test suite on one node cannot
show a second node's view, and `Encryptor.Ecto.SuspensionStore` has tests of
its own.
