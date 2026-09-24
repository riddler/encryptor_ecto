# Resolving the scope in jobs and projectors

This guide is for a host whose encrypted writes and reads do not all happen
in the request that knows the scope. A request fans work out to a `Task`, a
request enqueues a background job that runs later, and an event projector
builds a read model from events that belong to many scopes. Each of those
runs in a process that never set a scope, and each needs one.

The worked host is a catalog service for libraries. Each library is a scope:
its patrons' email addresses are encrypted under its own key. The request
registers patrons, a background job sends a patron an overdue notice, and a
projector turns loan events into a read model the catalog's screens query.
Everything below compiles and runs:
`test/encryptor/ecto/scope_in_jobs_guide_test.exs` runs this guide's code
against a real vault and real tables.

It assumes one scoped vault, `Library.Vault`, whose scope is the library,
configured as in the `## Configuring it` section of
`Encryptor.Ecto.KeyStore`, or as the customer vault of the
[two-vaults guide](two-vaults-customer-and-agreement.md).

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

The field type used for patrons reads the process scope, the default:

```elixir
defmodule Library.Encrypted.String do
  use Encryptor.Ecto.String, vault: Library.Vault
end
```

```elixir
defmodule Library.Patron do
  use Ecto.Schema

  schema "patrons" do
    field :library_id, :string
    field :email, Library.Encrypted.String
  end
end
```

## Step 2. Carry the scope into a Task

Read the scope in the caller, before the process boundary, and re-establish
it inside the new process with `Encryptor.Ecto.Scope.wrap/2`:

```elixir
defmodule Library.Patrons do
  alias Encryptor.Ecto.Scope
  alias Library.Patron
  alias Library.Repo

  def register(email) do
    Repo.insert!(%Patron{library_id: Scope.fetch!(), email: email})
  end

  def register_all_async(emails) do
    scope = Scope.fetch!()

    Task.async(fn ->
      Scope.wrap(scope, fn -> Enum.map(emails, &register/1) end)
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
defmodule Library.OverdueNotices do
  alias Encryptor.Ecto.Scope
  alias Library.Patron
  alias Library.Repo

  def job_args(patron_id) do
    %{"library_id" => Scope.fetch!(), "patron_id" => patron_id}
  end

  def perform(%{"library_id" => library_id, "patron_id" => patron_id}) do
    Scope.wrap(library_id, fn ->
      %Patron{email: email} = Repo.get!(Patron, patron_id)
      {:ok, email}
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
defmodule Library.Workers.OverdueNotice do
  use Oban.Worker, queue: :notices

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}), do: Library.OverdueNotices.perform(args)
end
```

```elixir
patron_id
|> Library.OverdueNotices.job_args()
|> Library.Workers.OverdueNotice.new()
|> Oban.insert()
```

Keeping the work in a plain module rather than in the worker means the job
can be tested, and run from a console, without a queue. The scope travels as
the library id, a routing identifier the host already stores in plaintext
columns; it is not a secret, and it is the only thing the job needs to
resolve the key.

## Step 4. Feed a projector's resolver from the event

A projector is different in kind. It writes rows for every library, one
event after another, in one process: inline, in the process of the command
that emitted the event, and on a rebuild, in a single process replaying the
whole event log. The scope of each write is the library on the event, not
the scope of the process doing the writing.

A resolver cannot read the library id off the row it is writing. An
`Ecto.Type` callback never sees the struct (ADR-0001 decision 5, the first
of its "Alternatives considered"), and
`c:Encryptor.Ecto.ScopeContext.resolve/2` is handed the field's declared
vault, table and column and nothing about the row. So the code that holds
the event puts the library id where the resolver reads it - the arrangement
`Encryptor.Ecto.Migrator.RowScope` makes for a migration plan that says
`scope_from :some_column`.

The resolver keeps the value in a process key of its own, not in
`Encryptor.Ecto.Scope`:

```elixir
defmodule Library.LoanScope do
  @behaviour Encryptor.Ecto.ScopeContext

  @key {__MODULE__, :library_id}

  def with_library(library_id, fun) when is_binary(library_id) and is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, library_id)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @impl Encryptor.Ecto.ScopeContext
  def resolve(_operation, _params) do
    case Process.get(@key) do
      library_id when is_binary(library_id) -> {:ok, library_id}
      nil -> {:error, :no_library_for_projection}
    end
  end
end
```

A key of its own is what makes the inline case safe. The command's process
has a process scope of its own, and the projector neither reads it nor
overwrites it: a projection written inside a request is under the event's
library whatever the request's scope is, and the request's scope is
untouched afterwards. `with_library/2` restores what was there before, in an
`after`, so a raising write cannot leave one event's library behind for the
next event. `resolve/2` answers `{:error, _}` when nothing is set, and the
type then raises `Encryptor.Ecto.MissingScopeError` rather than writing a
row under a key that is not its own.

The type names the resolver, and the read model names the type:

```elixir
defmodule Library.Encrypted.LoanString do
  use Encryptor.Ecto.String,
    vault: Library.Vault,
    scope: Library.LoanScope
end
```

```elixir
defmodule Library.LoanView do
  use Ecto.Schema

  schema "loan_views" do
    field :library_id, :string
    field :title, :string
    field :patron_email, Library.Encrypted.LoanString
  end
end
```

The projector hands each event's library id to the resolver, and the read
side hands it the library id it filters by:

```elixir
defmodule Library.LoanProjector do
  import Ecto.Query, only: [from: 2]

  alias Library.LoanScope
  alias Library.LoanView
  alias Library.Repo

  def project(%{"type" => "loan_recorded", "library_id" => library_id} = event) do
    LoanScope.with_library(library_id, fn ->
      Repo.insert!(%LoanView{
        library_id: library_id,
        title: event["title"],
        patron_email: event["patron_email"]
      })
    end)
  end

  def replay(events), do: Enum.each(events, &project/1)

  def list(library_id) do
    LoanScope.with_library(library_id, fn ->
      Repo.all(from(v in LoanView, where: v.library_id == ^library_id))
    end)
  end
end
```

`replay/1` walks events from many libraries in one process, and each write
is under its own event's library. `list/1`'s filter is not optional: the
scope is one value per load, so a query whose rows span libraries raises
`Encryptor.Ecto.DecryptError` on the first row of another library.

Both types name the same vault and resolve to the same library id, so a
projection row is under its library's key like that library's patron rows,
and a shred of the library's key reaches both.

## What this guide checked

`test/encryptor/ecto/scope_in_jobs_guide_test.exs` compiles every module
block above except the Oban worker, with the repo, the vault and the
`Library` prefix swapped for the test suite's own, and fails when a block and
the tested code differ. The Oban worker is checked to delegate to
`Library.OverdueNotices.perform/1`, since Oban is not a dependency of this
package. The test then shows that a new process starts with no scope, runs
the `Task` of Step 2 and the job of Step 3 in processes of their own - the
job's arguments through a JSON round trip first - and replays interleaved
events of two libraries through the projector of Step 4, with no process
scope at all and inline under the other library's process scope.
