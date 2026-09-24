defmodule Encryptor.Ecto.ScopeInJobsGuideTest do
  @moduledoc """
  The scope-in-jobs guide's host, run against a real vault and real tables.

  `docs/guides/scope-in-jobs-and-projectors.md` shows a host carrying the
  scope into a `Task`, into a background job, and into an event projector.
  `Encryptor.Ecto.TestScopeInJobs` is that code; the first tests below hold it
  to the guide's text, and the rest assert what the guide says happens, one
  describe per step.

  Every process the guide talks about is a real one here: the `Task` of
  Step 2 is a `Task`, and the job of Step 3 runs in a `Task` of its own - the
  stand-in for a queue process - after a JSON round trip of its arguments.
  """

  use Encryptor.Ecto.RepoCase, async: true

  alias Encryptor.Ecto.DecryptError
  alias Encryptor.Ecto.MissingScopeError
  alias Encryptor.Ecto.Scope
  alias Encryptor.Ecto.TestScopeInJobs.LoanProjector
  alias Encryptor.Ecto.TestScopeInJobs.LoanScope
  alias Encryptor.Ecto.TestScopeInJobs.LoanView
  alias Encryptor.Ecto.TestScopeInJobs.OverdueNotices
  alias Encryptor.Ecto.TestScopeInJobs.Patron
  alias Encryptor.Ecto.TestScopeInJobs.Patrons

  @guide Path.expand("../../../docs/guides/scope-in-jobs-and-projectors.md", __DIR__)
  @support Path.expand("../../support/test_scope_in_jobs.ex", __DIR__)

  # The substitutions `Encryptor.Ecto.TestScopeInJobs`'s moduledoc names, in
  # the order they apply: the repo alias, the repo, the vault, then the
  # general prefix.
  @substitutions [
    {"alias Library.Repo", "alias Encryptor.Ecto.TestRepo, as: Repo"},
    {"Library.Repo", "Encryptor.Ecto.TestRepo"},
    {"Library.Vault", "Encryptor.Ecto.TestVaults.Merchant"},
    {"Library.", "Encryptor.Ecto.TestScopeInJobs."}
  ]

  # The two selectors `Encryptor.Ecto.TestVaults.Merchant` holds keys for,
  # standing in for two libraries' ids.
  @library "merchant_7f3"
  @other_library "merchant_a19"

  setup do
    Scope.clear()
    :ok
  end

  describe "the guide's code" do
    # Sabotage: changed the guide's resolver error atom to
    # `:no_library_for_event`; this test went red on that block. Every
    # support-file sabotage below also turned this test red.
    test "every defmodule block in the guide, but the Oban worker, is the support file's code" do
      source = File.read!(@support)
      support = source |> strip_moduledocs() |> without_aliases() |> normalize()
      blocks = Enum.reject(guide_modules(), &oban_worker?/1)

      assert length(blocks) == 8

      for block <- Enum.map(blocks, &substitute/1) do
        assert String.contains?(support, block |> without_aliases() |> normalize()),
               "guide block not found in the support file:\n\n" <> block

        for alias_line <- aliases(block) do
          assert String.contains?(source, alias_line),
                 "guide alias not found in the support file: " <> alias_line
        end
      end
    end

    # Sabotage: changed the worker block to delegate to
    # `Library.OverdueNotices.run/1`; the delegation assertion went red.
    test "the Oban worker block delegates to the tested perform/1" do
      assert [worker] = Enum.filter(guide_modules(), &oban_worker?/1)

      assert worker =~
               "def perform(%Oban.Job{args: args}), do: Library.OverdueNotices.perform(args)"

      assert {:module, OverdueNotices} = Code.ensure_loaded(OverdueNotices)
      assert function_exported?(OverdueNotices, :perform, 1)
    end
  end

  describe "step 1: the scope stops at the process" do
    # Sabotage: made `Encryptor.Ecto.Scope.get/0` answer a library when
    # nothing was set; the `:error` assertion went red.
    test "a process started inside a scope has none" do
      assert :error =
               Scope.wrap(@library, fn ->
                 fn -> Scope.get() end |> Task.async() |> Task.await()
               end)
    end

    # Sabotage: made `Encryptor.Ecto.ScopeContext.Process.resolve/2` answer
    # a fixed library when no scope was set; the insert went through.
    test "a scoped write from that process raises rather than guessing" do
      write = fn ->
        try do
          TestRepo.insert!(%Patron{library_id: @library, email: "reader@example.com"})
        rescue
          error in MissingScopeError -> error
        end
      end

      assert %MissingScopeError{} =
               Scope.wrap(@library, fn -> write |> Task.async() |> Task.await() end)
    end
  end

  describe "step 2: carry the scope into a Task" do
    # Sabotage: dropped the `Scope.wrap/2` inside `register_all_async/1`'s
    # task; the task raised on `Scope.fetch!/0` and the test went red.
    test "the task writes under the caller's scope" do
      patrons =
        Scope.wrap(@library, fn ->
          ["one@example.com", "two@example.com"]
          |> Patrons.register_all_async()
          |> Task.await()
        end)

      assert [%Patron{library_id: @library}, %Patron{library_id: @library}] = patrons

      for %Patron{id: id, email: email} <- patrons do
        assert %Patron{email: ^email} = Scope.wrap(@library, fn -> TestRepo.get!(Patron, id) end)

        assert_raise DecryptError, fn ->
          Scope.wrap(@other_library, fn -> TestRepo.get!(Patron, id) end)
        end
      end

      assert :error = Scope.get()
    end
  end

  describe "step 3: carry the scope into a background job" do
    # Sabotage: dropped the `Scope.wrap/2` from `OverdueNotices.perform/1`;
    # the load raised `MissingScopeError` in the job's process and the test
    # went red. Separately, made `job_args/1` put the library id under an
    # atom key; the JSON round trip turned it into a string key and the
    # round-trip assertions went red.
    test "the job's arguments carry the scope through JSON to perform/1" do
      %Patron{id: id} =
        Scope.wrap(@library, fn ->
          TestRepo.insert!(%Patron{library_id: @library, email: "late@example.com"})
        end)

      args = Scope.wrap(@library, fn -> OverdueNotices.job_args(id) end)

      decoded = args |> Jason.encode!() |> Jason.decode!()
      assert %{"library_id" => @library, "patron_id" => ^id} = decoded
      assert decoded == args

      assert {:ok, "late@example.com"} =
               fn -> OverdueNotices.perform(decoded) end |> Task.async() |> Task.await()
    end
  end

  describe "step 4: feed a projector's resolver from the event" do
    # Sabotage: made `LoanProjector.project/1` hand `LoanScope` one fixed
    # library for every event; this test went red.
    test "a replay of two libraries' events writes each under its own library" do
      LoanProjector.replay([
        loan(@library, "Middlemarch", "one@example.com"),
        loan(@other_library, "Persuasion", "two@example.com"),
        loan(@library, "Emma", "three@example.com")
      ])

      assert [
               %LoanView{title: "Middlemarch", patron_email: "one@example.com"},
               %LoanView{title: "Emma", patron_email: "three@example.com"}
             ] = @library |> LoanProjector.list() |> Enum.sort_by(& &1.id)

      assert [%LoanView{title: "Persuasion", patron_email: "two@example.com"}] =
               LoanProjector.list(@other_library)

      assert :error = Scope.get()
    end

    # Sabotage: made `LoanScope.resolve/2` read the process scope's key
    # instead of its own; this test went red.
    test "an inline projection ignores the request's scope and leaves it as it was" do
      Scope.wrap(@other_library, fn ->
        LoanProjector.project(loan(@library, "Middlemarch", "one@example.com"))

        assert {:ok, @other_library} = Scope.get()
      end)

      assert [%LoanView{patron_email: "one@example.com"}] = LoanProjector.list(@library)
      assert [] = LoanProjector.list(@other_library)
    end

    # Sabotage: made `LoanScope.resolve/2` answer `{:ok, "merchant_7f3"}`
    # when nothing was set; the insert went through.
    test "outside with_library/2 the resolver refuses, and the type raises" do
      assert_raise MissingScopeError, fn ->
        Scope.wrap(@library, fn ->
          TestRepo.insert!(%LoanView{library_id: @library, patron_email: "one@example.com"})
        end)
      end
    end

    # Sabotage: dropped the `where:` from `LoanProjector.list/1`; `list/1`
    # raised `DecryptError` on the other library's row.
    test "a read whose rows span libraries raises instead of answering" do
      LoanProjector.replay([
        loan(@library, "Middlemarch", "one@example.com"),
        loan(@other_library, "Persuasion", "two@example.com")
      ])

      assert [_view] = LoanProjector.list(@library)

      assert_raise DecryptError, fn ->
        LoanScope.with_library(@library, fn -> TestRepo.all(LoanView) end)
      end
    end
  end

  defp loan(library_id, title, email) do
    %{
      "type" => "loan_recorded",
      "library_id" => library_id,
      "title" => title,
      "patron_email" => email
    }
  end

  defp guide_modules do
    ~r/```elixir\n(.*?)```/s
    |> Regex.scan(File.read!(@guide), capture: :all_but_first)
    |> Enum.map(fn [block] -> block end)
    |> Enum.filter(&String.starts_with?(&1, "defmodule "))
  end

  defp oban_worker?(block), do: String.contains?(block, "use Oban.Worker")

  defp substitute(block) do
    Enum.reduce(@substitutions, block, fn {from, to}, acc -> String.replace(acc, from, to) end)
  end

  defp strip_moduledocs(source) do
    source
    |> String.replace(~r/\n  @moduledoc """\n.*?\n  """\n/s, "\n")
    |> String.replace(~r/\n  @moduledoc "[^"\n]*"\n/, "\n")
  end

  # Alias lines are compared one by one rather than in place: credo orders a
  # module's aliases alphabetically, and the substituted repo alias sorts to a
  # different line in each file.
  defp aliases(block) do
    ~r/^\s*(alias .+)$/m
    |> Regex.scan(block, capture: :all_but_first)
    |> Enum.map(fn [line] -> line end)
  end

  defp without_aliases(source), do: String.replace(source, ~r/^\s*alias .+\n/m, "")

  # Line breaks are the formatter's, and a longer module name moves them, so
  # the comparison is over tokens rather than layout.
  defp normalize(source) do
    source
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/([(\[{]) /, "\\1")
    |> String.replace(~r/ ([)\]}])/, "\\1")
    |> String.trim()
  end
end
