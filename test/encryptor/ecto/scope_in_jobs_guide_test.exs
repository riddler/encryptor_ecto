defmodule Encryptor.Ecto.ScopeInJobsGuideTest do
  @moduledoc """
  The scope-in-jobs guide's host, run against a real vault and real tables.

  `docs/guides/scope-in-jobs-and-projectors.md` shows a host carrying the
  scope into a `Task`, into a background job, and into an event projector,
  inline and as a handler process of its own.
  `Encryptor.Ecto.TestScopeInJobs` is that code; the first tests below hold it
  to the guide's text, and the rest assert what the guide says happens, one
  describe per step.

  Every process the guide talks about is a real one here: the `Task` of
  Step 2 is a `Task`, and the job of Step 3 runs in a `Task` of its own - the
  stand-in for a queue process - after a JSON round trip of its arguments,
  and the handler of Step 5 is a `GenServer` the test starts.
  """

  use Encryptor.Ecto.RepoCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Encryptor.Ecto.DecryptError
  alias Encryptor.Ecto.MissingScopeError
  alias Encryptor.Ecto.Scope
  alias Encryptor.Ecto.TestScopeInJobs.Item
  alias Encryptor.Ecto.TestScopeInJobs.ItemProjector
  alias Encryptor.Ecto.TestScopeInJobs.Items
  alias Encryptor.Ecto.TestScopeInJobs.ItemView
  alias Encryptor.Ecto.TestScopeInJobs.ProjectionHandler
  alias Encryptor.Ecto.TestScopeInJobs.ProjectionScope
  alias Encryptor.Ecto.TestScopeInJobs.Reminders

  @guide Path.expand("../../../docs/guides/scope-in-jobs-and-projectors.md", __DIR__)
  @support Path.expand("../../support/test_scope_in_jobs.ex", __DIR__)

  # The substitutions `Encryptor.Ecto.TestScopeInJobs`'s moduledoc names, in
  # the order they apply: the repo alias, the repo, the vault, then the
  # general prefix.
  @substitutions [
    {"alias MyApp.Repo", "alias Encryptor.Ecto.TestRepo, as: Repo"},
    {"MyApp.Repo", "Encryptor.Ecto.TestRepo"},
    {"MyApp.Vault", "Encryptor.Ecto.TestVaults.Merchant"},
    {"MyApp.", "Encryptor.Ecto.TestScopeInJobs."}
  ]

  # The two selectors `Encryptor.Ecto.TestVaults.Merchant` holds keys for,
  # standing in for two owners' ids.
  @owner "merchant_7f3"
  @other_owner "merchant_a19"

  setup do
    Scope.clear()
    :ok
  end

  describe "the guide's code" do
    # Sabotage: changed the guide's resolver error atom to
    # `:no_owner_for_event`; this test went red on that block. Every
    # support-file sabotage below also turned this test red.
    test "every defmodule block in the guide, but the Oban worker, is the support file's code" do
      source = File.read!(@support)
      support = source |> strip_moduledocs() |> without_aliases() |> normalize()
      blocks = Enum.reject(guide_modules(), &oban_worker?/1)

      assert length(blocks) == 10

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
    # `MyApp.Reminders.run/1`; the delegation assertion went red.
    test "the Oban worker block delegates to the tested perform/1" do
      assert [worker] = Enum.filter(guide_modules(), &oban_worker?/1)

      assert worker =~
               "def perform(%Oban.Job{args: args}), do: MyApp.Reminders.perform(args)"

      assert {:module, Reminders} = Code.ensure_loaded(Reminders)
      assert function_exported?(Reminders, :perform, 1)
    end
  end

  describe "step 1: the scope stops at the process" do
    # Sabotage: made `Encryptor.Ecto.Scope.get/0` answer an owner when
    # nothing was set; the `:error` assertion went red.
    test "a process started inside a scope has none" do
      assert :error =
               Scope.wrap(@owner, fn ->
                 fn -> Scope.get() end |> Task.async() |> Task.await()
               end)
    end

    # Sabotage: made `Encryptor.Ecto.ScopeContext.Process.resolve/2` answer
    # a fixed owner when no scope was set; the insert went through.
    test "a scoped write from that process raises rather than guessing" do
      write = fn ->
        try do
          TestRepo.insert!(%Item{owner_id: @owner, note: "note-1"})
        rescue
          error in MissingScopeError -> error
        end
      end

      assert %MissingScopeError{} =
               Scope.wrap(@owner, fn -> write |> Task.async() |> Task.await() end)
    end
  end

  describe "step 2: carry the scope into a Task" do
    # Sabotage: dropped the `Scope.wrap/2` inside `register_all_async/1`'s
    # task; the task raised on `Scope.fetch!/0` and the test went red.
    test "the task writes under the caller's scope" do
      items =
        Scope.wrap(@owner, fn ->
          ["note-1", "note-2"]
          |> Items.register_all_async()
          |> Task.await()
        end)

      assert [%Item{owner_id: @owner}, %Item{owner_id: @owner}] = items

      for %Item{id: id, note: note} <- items do
        assert %Item{note: ^note} = Scope.wrap(@owner, fn -> TestRepo.get!(Item, id) end)

        assert_raise DecryptError, fn ->
          Scope.wrap(@other_owner, fn -> TestRepo.get!(Item, id) end)
        end
      end

      assert :error = Scope.get()
    end
  end

  describe "step 3: carry the scope into a background job" do
    # Sabotage: dropped the `Scope.wrap/2` from `Reminders.perform/1`;
    # the load raised `MissingScopeError` in the job's process and the test
    # went red. Separately, made `job_args/1` put the owner id under an
    # atom key; the JSON round trip turned it into a string key and the
    # round-trip assertions went red.
    test "the job's arguments carry the scope through JSON to perform/1" do
      %Item{id: id} =
        Scope.wrap(@owner, fn ->
          TestRepo.insert!(%Item{owner_id: @owner, note: "note-3"})
        end)

      args = Scope.wrap(@owner, fn -> Reminders.job_args(id) end)

      decoded = args |> Jason.encode!() |> Jason.decode!()
      assert %{"owner_id" => @owner, "item_id" => ^id} = decoded
      assert decoded == args

      assert {:ok, "note-3"} =
               fn -> Reminders.perform(decoded) end |> Task.async() |> Task.await()
    end
  end

  describe "step 4: feed a projector's resolver from the event" do
    # Sabotage: made `ItemProjector.project/1` hand `ProjectionScope` one fixed
    # owner for every event; this test went red.
    test "a replay of two owners' events writes each under its own owner" do
      ItemProjector.replay([
        item_event(@owner, "Title A", "note-1"),
        item_event(@other_owner, "Title B", "note-2"),
        item_event(@owner, "Title C", "note-3")
      ])

      assert [
               %ItemView{title: "Title A", note: "note-1"},
               %ItemView{title: "Title C", note: "note-3"}
             ] = @owner |> ItemProjector.list() |> Enum.sort_by(& &1.id)

      assert [%ItemView{title: "Title B", note: "note-2"}] =
               ItemProjector.list(@other_owner)

      assert :error = Scope.get()
    end

    # Sabotage: made `ProjectionScope.resolve/2` read the process scope's key
    # instead of its own; this test went red.
    test "an inline projection ignores the request's scope and leaves it as it was" do
      Scope.wrap(@other_owner, fn ->
        ItemProjector.project(item_event(@owner, "Title A", "note-1"))

        assert {:ok, @other_owner} = Scope.get()
      end)

      assert [%ItemView{note: "note-1"}] = ItemProjector.list(@owner)
      assert [] = ItemProjector.list(@other_owner)
    end

    # Sabotage: made `ProjectionScope.resolve/2` answer `{:ok, "merchant_7f3"}`
    # when nothing was set; the insert went through.
    test "outside with_owner/2 the resolver refuses, and the type raises" do
      assert_raise MissingScopeError, fn ->
        Scope.wrap(@owner, fn ->
          TestRepo.insert!(%ItemView{owner_id: @owner, note: "note-1"})
        end)
      end
    end

    # Sabotage: dropped the `where:` from `ItemProjector.list/1`; `list/1`
    # raised `DecryptError` on the other owner's row.
    test "a read whose rows span owners raises instead of answering" do
      ItemProjector.replay([
        item_event(@owner, "Title A", "note-1"),
        item_event(@other_owner, "Title B", "note-2")
      ])

      assert [_view] = ItemProjector.list(@owner)

      assert_raise DecryptError, fn ->
        ProjectionScope.with_owner(@owner, fn -> TestRepo.all(ItemView) end)
      end
    end
  end

  describe "step 5: run the projector in a process of its own" do
    setup do
      handler = start_supervised!(ProjectionHandler)
      Sandbox.allow(TestRepo, self(), handler)
      %{handler: handler}
    end

    # Sabotage: made `ItemViews.fetch!/1` wrap the load in
    # `ProjectionScope.with_owner("merchant_7f3", ...)` instead of the row's own
    # owner id; the read-back of the other owner's row raised
    # `DecryptError` and this test went red. Separately, dropped the
    # `ItemProjector.project/1` call from the handler's `handle_info/2`; no
    # row was written and the listing assertion went red.
    test "events from any process are written under their own owner and read back by id alone",
         %{handler: handler} do
      send(handler, {:event, item_event(@owner, "Title A", "note-1")})

      Scope.wrap(@owner, fn ->
        send(handler, {:event, item_event(@other_owner, "Title B", "note-2")})
      end)

      # A call after the sends: the handler has handled both events by the
      # time it answers, since messages from one sender arrive in order.
      :sys.get_state(handler)

      assert [{first_id, @owner}, {second_id, @other_owner}] =
               TestRepo.all(from(v in ItemView, order_by: v.id, select: {v.id, v.owner_id}))

      assert %ItemView{title: "Title A", note: "note-1"} =
               Scope.wrap(@other_owner, fn ->
                 ProjectionHandler.fetch_view(handler, first_id)
               end)

      assert %ItemView{title: "Title B", note: "note-2"} =
               ProjectionHandler.fetch_view(handler, second_id)

      assert :error = Scope.get()
    end
  end

  defp item_event(owner_id, title, note) do
    %{
      "type" => "item_recorded",
      "owner_id" => owner_id,
      "title" => title,
      "note" => note
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
