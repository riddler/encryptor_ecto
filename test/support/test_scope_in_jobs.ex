defmodule Encryptor.Ecto.TestScopeInJobs do
  @moduledoc """
  The scope-in-jobs guide's host, compiled and run.

  `docs/guides/scope-in-jobs-and-projectors.md` shows a generic SaaS host - a
  catalog service for libraries, one scope per library - carrying the scope
  into a `Task`, into a background job, and into an event projector. Every
  module below is one of the guide's code blocks with these literal
  substitutions and nothing else:

    * `alias Library.Repo` is `alias Encryptor.Ecto.TestRepo, as: Repo`, and
      any other `Library.Repo` is `Encryptor.Ecto.TestRepo`;
    * `Library.Vault` is `Encryptor.Ecto.TestVaults.Merchant`, the suite's
      scoped vault, which `test/test_helper.exs` starts;
    * every other `Library.` prefix is `Encryptor.Ecto.TestScopeInJobs.`.

  One guide block is not here: the Oban worker, because Oban is not a
  dependency of this package. It is one line of delegation to
  `Encryptor.Ecto.TestScopeInJobs.OverdueNotices.perform/1`, which is here,
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
  @moduledoc "The guide's process-scoped type: the scope is the library in scope."

  use Encryptor.Ecto.String, vault: Encryptor.Ecto.TestVaults.Merchant
end

defmodule Encryptor.Ecto.TestScopeInJobs.Patron do
  @moduledoc "The guide's patron: one library's reader, with an encrypted address."

  use Ecto.Schema

  schema "patrons" do
    field :library_id, :string
    field :email, Encryptor.Ecto.TestScopeInJobs.Encrypted.String
  end
end

defmodule Encryptor.Ecto.TestScopeInJobs.Patrons do
  @moduledoc "The guide's request-side code, and the `Task` that carries the scope."

  alias Encryptor.Ecto.Scope
  alias Encryptor.Ecto.TestRepo, as: Repo
  alias Encryptor.Ecto.TestScopeInJobs.Patron

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

defmodule Encryptor.Ecto.TestScopeInJobs.OverdueNotices do
  @moduledoc "The guide's job: the scope rides in the args, and `perform/1` re-establishes it."

  alias Encryptor.Ecto.Scope
  alias Encryptor.Ecto.TestRepo, as: Repo
  alias Encryptor.Ecto.TestScopeInJobs.Patron

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

defmodule Encryptor.Ecto.TestScopeInJobs.LoanScope do
  @moduledoc "The guide's projector resolver: the library id from the event, in a key of its own."

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

defmodule Encryptor.Ecto.TestScopeInJobs.Encrypted.LoanString do
  @moduledoc "The guide's projection type: the scope is whatever `LoanScope` was given."

  use Encryptor.Ecto.String,
    vault: Encryptor.Ecto.TestVaults.Merchant,
    scope: Encryptor.Ecto.TestScopeInJobs.LoanScope
end

defmodule Encryptor.Ecto.TestScopeInJobs.LoanView do
  @moduledoc "The guide's read model: one row per loan event."

  use Ecto.Schema

  schema "loan_views" do
    field :library_id, :string
    field :title, :string
    field :patron_email, Encryptor.Ecto.TestScopeInJobs.Encrypted.LoanString
  end
end

defmodule Encryptor.Ecto.TestScopeInJobs.LoanProjector do
  @moduledoc "The guide's projector: each event's library id is handed to `LoanScope`."

  import Ecto.Query, only: [from: 2]

  alias Encryptor.Ecto.TestRepo, as: Repo
  alias Encryptor.Ecto.TestScopeInJobs.LoanScope
  alias Encryptor.Ecto.TestScopeInJobs.LoanView

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
