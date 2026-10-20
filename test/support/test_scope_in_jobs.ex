defmodule Encryptor.Ecto.TestScopeInJobs do
  @moduledoc """
  The scope-in-jobs guide's host, compiled and run.

  `docs/guides/scope-in-jobs-and-projectors.md` shows a host with one scope per
  owner carrying the scope into a `Task`, into a background job, and into an
  event projector. Every module below is one of the guide's code blocks with these literal
  substitutions and nothing else:

    * `alias MyApp.Repo` is `alias Encryptor.Ecto.TestRepo, as: Repo`, and
      any other `MyApp.Repo` is `Encryptor.Ecto.TestRepo`;
    * `MyApp.Vault` is `Encryptor.Ecto.TestVaults.Merchant`, the suite's
      scoped vault, which `test/test_helper.exs` starts;
    * every other `MyApp.` prefix is `Encryptor.Ecto.TestScopeInJobs.`.

  One guide block is not here: the Oban worker, because Oban is not a
  dependency of this package. It is one line of delegation to
  `Encryptor.Ecto.TestScopeInJobs.Reminders.perform/1`, which is here,
  and `Encryptor.Ecto.ScopeInJobsGuideTest` checks that the block delegates
  to it and runs that function in a process of its own, the way a queue
  would.

  The same test holds every other block to this file: it reads the guide,
  applies the substitutions, and asserts each `defmodule` block appears here
  verbatim once the moduledocs below are set aside.

  Nothing in `lib/` names any of this.
  """
end

defmodule Encryptor.Ecto.TestScopeInJobs.Encrypted.String do
  @moduledoc "The guide's process-scoped type: the scope is the owner in scope."

  use Encryptor.Ecto.String, vault: Encryptor.Ecto.TestVaults.Merchant
end

defmodule Encryptor.Ecto.TestScopeInJobs.Item do
  @moduledoc "The guide's item: one owner's item, with an encrypted note."

  use Ecto.Schema

  schema "items" do
    field :owner_id, :string
    field :note, Encryptor.Ecto.TestScopeInJobs.Encrypted.String
  end
end

defmodule Encryptor.Ecto.TestScopeInJobs.Items do
  @moduledoc "The guide's request-side code, and the `Task` that carries the scope."

  alias Encryptor.Ecto.Scope
  alias Encryptor.Ecto.TestRepo, as: Repo
  alias Encryptor.Ecto.TestScopeInJobs.Item

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

defmodule Encryptor.Ecto.TestScopeInJobs.Reminders do
  @moduledoc "The guide's job: the scope rides in the args, and `perform/1` re-establishes it."

  alias Encryptor.Ecto.Scope
  alias Encryptor.Ecto.TestRepo, as: Repo
  alias Encryptor.Ecto.TestScopeInJobs.Item

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

defmodule Encryptor.Ecto.TestScopeInJobs.ProjectionScope do
  @moduledoc "The guide's projector resolver: the owner id from the event, in a key of its own."

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

defmodule Encryptor.Ecto.TestScopeInJobs.Encrypted.ProjectionString do
  @moduledoc "The guide's projection type: the scope is whatever `ProjectionScope` was given."

  use Encryptor.Ecto.String,
    vault: Encryptor.Ecto.TestVaults.Merchant,
    scope: Encryptor.Ecto.TestScopeInJobs.ProjectionScope
end

defmodule Encryptor.Ecto.TestScopeInJobs.ItemView do
  @moduledoc "The guide's read model: one row per item event."

  use Ecto.Schema

  schema "item_views" do
    field :owner_id, :string
    field :title, :string
    field :note, Encryptor.Ecto.TestScopeInJobs.Encrypted.ProjectionString
  end
end

defmodule Encryptor.Ecto.TestScopeInJobs.ItemProjector do
  @moduledoc "The guide's projector: each event's owner id is handed to `ProjectionScope`."

  import Ecto.Query, only: [from: 2]

  alias Encryptor.Ecto.TestRepo, as: Repo
  alias Encryptor.Ecto.TestScopeInJobs.ItemView
  alias Encryptor.Ecto.TestScopeInJobs.ProjectionScope

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

defmodule Encryptor.Ecto.TestScopeInJobs.ItemViews do
  @moduledoc "The guide's read-back: the row's own owner id first, then the row under it."

  import Ecto.Query, only: [from: 2]

  alias Encryptor.Ecto.TestRepo, as: Repo
  alias Encryptor.Ecto.TestScopeInJobs.ItemView
  alias Encryptor.Ecto.TestScopeInJobs.ProjectionScope

  def fetch!(id) do
    owner_id = Repo.one!(from(v in ItemView, where: v.id == ^id, select: v.owner_id))

    ProjectionScope.with_owner(owner_id, fn -> Repo.get!(ItemView, id) end)
  end
end

defmodule Encryptor.Ecto.TestScopeInJobs.ProjectionHandler do
  @moduledoc "The guide's handler process: events in by message, read-backs by call."

  use GenServer

  alias Encryptor.Ecto.TestScopeInJobs.ItemProjector
  alias Encryptor.Ecto.TestScopeInJobs.ItemViews

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
