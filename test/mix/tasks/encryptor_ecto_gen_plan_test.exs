defmodule Mix.Tasks.Encryptor.Ecto.Gen.PlanTest do
  @moduledoc """
  `mix encryptor.ecto.gen.plan`: what it finds, what it refuses to guess.

  ADR-0004 decision 7 gives this generator three behaviours that each read as
  a defect - a skeleton that does not compile, a `to:` that is a comment, and
  a field list that over-reports - and the assertions below are mostly about
  keeping them. A test suite is the obvious place for somebody to "fix" one of
  them, so each is asserted positively, with the reason attached: guessing the
  tenant column re-encrypts every row under one tenant's key, and a skeleton
  that compiles is a skeleton somebody runs.

  The fixture schemas live in this file rather than in `test/support/`. They
  exist to pin type-detection edges - Ecto's own type modules, a composite, an
  embedded schema - which nothing else in the suite needs, and a fixture only
  one file reads is clearer beside its tests than in a shared module.

  Everything that writes writes through an explicit `--output` into a
  temporary directory, so no test writes into this project's own `lib/`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Encryptor.Ecto.Gen.Plan

  defmodule Fixtures do
    @moduledoc false

    defmodule Cipher do
      @moduledoc false
      use Ecto.Type

      @impl Ecto.Type
      def type, do: :binary
      @impl Ecto.Type
      def cast(value), do: {:ok, value}
      @impl Ecto.Type
      def load(value), do: {:ok, value}
      @impl Ecto.Type
      def dump(value), do: {:ok, value}
    end

    defmodule Card do
      @moduledoc "A card-processing row: two module-typed columns among base-typed ones."
      use Ecto.Schema

      schema "gen_plan_cards" do
        field(:merchant_id, :string)
        field(:pan, Cipher)
        field(:notes, Cipher)
        field(:authorized_at, :utc_datetime)
      end
    end

    defmodule Signup do
      @moduledoc "A signup wizard's row, with only Ecto's own module types beside a candidate."
      use Ecto.Schema

      schema "gen_plan_signups" do
        field(:variant, Ecto.Enum, values: [:a, :b])
        field(:external_ref, Ecto.UUID)
        field(:email_encrypted, Cipher)
      end
    end

    defmodule Plain do
      @moduledoc "Every field a built-in type, so the schema is not reported at all."
      use Ecto.Schema

      schema "gen_plan_plain" do
        field(:name, :string)
        field(:count, :integer)
      end
    end

    defmodule Composites do
      @moduledoc "A composite-typed field, which is skipped and said to be skipped."
      use Ecto.Schema

      schema "gen_plan_composites" do
        field(:tags, {:array, Cipher})
        field(:pan, Cipher)
      end
    end

    defmodule Embedded do
      @moduledoc "An embedded schema has no table, so no rewrite can name it."
      use Ecto.Schema

      embedded_schema do
        field(:pan, Cipher)
      end
    end
  end

  @schemas [
    Fixtures.Card,
    Fixtures.Signup,
    Fixtures.Plain,
    Fixtures.Composites,
    Fixtures.Embedded
  ]

  setup do
    path = Path.join(System.tmp_dir!(), "ece-6ba-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)

    {:ok, dir: path, out: Path.join(path, "migration.ex")}
  end

  # -- what counts as a candidate -------------------------------------------

  # Sabotage: dropped the `Ecto.Type.base?/1` check, so every field became a
  # candidate - `:merchant_id` and `:authorized_at` were emitted as fields to
  # rewrite, and the generated plan told a host to re-encrypt its timestamps.
  test "finds module-typed fields and leaves built-in Ecto types alone" do
    assert [{Fixtures.Card, card}, {Fixtures.Composites, _}, {Fixtures.Signup, signup}] =
             Plan.candidates(@schemas)

    assert card == [pan: Fixtures.Cipher, notes: Fixtures.Cipher]
    assert signup == [email_encrypted: Fixtures.Cipher]
  end

  # Sabotage: made `host_module/1` return the module unconditionally instead of
  # excluding Ecto's own. `Ecto.Enum` and `Ecto.UUID` fields were reported as
  # encrypted candidates, which is noise of a different kind from decision 1's
  # deliberate over-reporting: nothing a host wrote is involved.
  test "Ecto's own type modules are not candidates" do
    assert [{Fixtures.Signup, fields}] = Plan.candidates([Fixtures.Signup])

    refute Keyword.has_key?(fields, :variant)
    refute Keyword.has_key?(fields, :external_ref)
  end

  test "a schema with no module-typed field is not reported at all" do
    assert Plan.candidates([Fixtures.Plain]) == []
  end

  # A composite's element type is not a module that reads the field's bytes, so
  # emitting `from:` for it would name the wrong reader. The moduledoc and the
  # nothing-found message both say to check these by hand.
  # Sabotage: made `from_module/1` recurse into `{:array, inner}`. The plan
  # then emitted `from:` naming the element type, which reads one value's
  # bytes and not the array's, so row one of the pass would have failed on a
  # field the generator claimed to understand.
  test "a composite-typed field is skipped while its schema's plain one is kept" do
    assert [{Fixtures.Composites, fields}] = Plan.candidates([Fixtures.Composites])

    assert fields == [pan: Fixtures.Cipher]
  end

  # Sabotage: dropped the `__schema__(:source)` check from `schema?/1`.
  # Embedded schemas were reported, and a `rewrite` naming one names no table
  # for the migrator to read.
  test "an embedded schema is skipped, having no table to rewrite" do
    assert Plan.candidates([Fixtures.Embedded]) == []
  end

  test "non-schema modules are ignored rather than raising" do
    assert Plan.candidates([Enum, Fixtures.Cipher, Fixtures.Card]) == [
             {Fixtures.Card, [pan: Fixtures.Cipher, notes: Fixtures.Cipher]}
           ]
  end

  # Sabotage: dropped the `Enum.sort/1`. Re-running the generator reordered the
  # rewrite blocks, so a regenerated plan produced a diff against itself with
  # no change of meaning in it.
  test "the schema order is stable, so re-running produces the same file" do
    assert Plan.candidates(@schemas) == Plan.candidates(Enum.reverse(@schemas))
  end

  # -- the three deliberate non-features ------------------------------------

  # Sabotage: emitted `tenant_from :merchant_id` by picking the first column
  # whose name ends in `_id`. The plan compiled, `mix encryptor.ecto.migrate`
  # ran, and every row of a table whose tenant is not `merchant_id` was
  # rewritten under one tenant's key - the exact failure ADR-0004 decision 7
  # refuses to make reachable.
  test "it emits a tenant column that does not exist, so the plan will not compile" do
    source = Plan.source(MyApp.Encryption.Migration, MyApp.Repo, Plan.candidates(@schemas))

    assert source =~ "tenant_from :TODO_tenant_column"
    refute source =~ "tenant_from :merchant_id"
    assert source =~ "THIS FILE DOES NOT COMPILE YET"
  end

  # Sabotage: emitted `to:` with the `from:` module repeated, on the theory
  # that a context change names the same module on both sides. Every generated
  # field then read as a decided one, and a reviewer approving the diff was
  # approving a target type nobody chose.
  test "it emits `to:` as a comment and never as a value" do
    source = Plan.source(MyApp.Encryption.Migration, MyApp.Repo, Plan.candidates(@schemas))

    assert source =~ "field :pan, from: #{inspect(Fixtures.Cipher)}"
    assert source =~ "# to: name the type module :pan is rewritten into"
    refute source =~ ~r/^\s*to:/m
    refute source =~ "to: #{inspect(Fixtures.Cipher)}"
  end

  test "it says in the file why it over-reports, and does not claim to be exhaustive" do
    source = Plan.source(MyApp.Encryption.Migration, MyApp.Repo, Plan.candidates(@schemas))

    assert source =~ "over-reports"
    assert source =~ "no other library's marker function"
    assert source =~ "not necessarily"
    assert source =~ "gen.plan"
  end

  # -- the generated source -------------------------------------------------

  test "what it writes is syntactically valid Elixir" do
    source = Plan.source(MyApp.Encryption.Migration, MyApp.Repo, Plan.candidates(@schemas))

    assert {:ok, _ast} = Code.string_to_quoted(source)
    assert source =~ "defmodule MyApp.Encryption.Migration do"
    assert source =~ "use Encryptor.Ecto.Migration, repo: MyApp.Repo"
  end

  # The promise of decision 7 end to end: the file parses, reaches the DSL, and
  # is stopped there by the tenant column rather than by a syntax error - a
  # skeleton that failed to parse would say nothing about which fact is missing.
  test "the DSL rejects the generated tenant column, naming the schema" do
    source =
      Plan.source(
        Encryptor.Ecto.GenPlanSkeleton,
        Encryptor.Ecto.TestRepo,
        Plan.candidates([Fixtures.Card])
      )

    assert {:ok, _ast} = Code.string_to_quoted(source)

    error = assert_raise CompileError, fn -> Code.compile_string(source) end
    message = Exception.message(error)

    assert message =~ "TODO_tenant_column"
    assert message =~ "tenant_from"
  end

  # -- the task ------------------------------------------------------------

  test "writes the plan where --output says, and reports what it found", %{out: out} do
    assert {0, output} = generate(["--repo", "MyApp.Repo", "--output", out])

    assert output =~ "* creating #{out}"
    assert output =~ "does not compile yet"

    source = File.read!(out)
    assert source =~ "use Encryptor.Ecto.Migration, repo: MyApp.Repo"
    assert source =~ "rewrite Encryptor.Ecto.TestSchemas.Card do"
    assert source =~ "field :pan, from: Encryptor.Ecto.TestTypes.Pan"
    assert source =~ "tenant_from :TODO_tenant_column"
  end

  test "--repo defaults to the application's single configured :ecto_repos", %{out: out} do
    assert {0, _output} = generate(["--output", out])

    assert File.read!(out) =~ "use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo"
  end

  test "--module names the generated module", %{out: out} do
    assert {0, _output} =
             generate(["--module", "MyApp.Encryption.CloakMigration", "--output", out])

    assert File.read!(out) =~ "defmodule MyApp.Encryption.CloakMigration do"
  end

  test "an Elixir.-prefixed --module is accepted and written unprefixed", %{out: out} do
    assert {0, _output} = generate(["--module", "Elixir.MyApp.Plan", "--output", out])

    assert File.read!(out) =~ "defmodule MyApp.Plan do"
  end

  test "the defaults derive the module and its path from the project" do
    assert Plan.default_module() == EncryptorEcto.Encryption.Migration
    assert Plan.default_output(MyApp.Encryption.Migration) == "lib/my_app/encryption/migration.ex"
  end

  # Sabotage: dropped `unwritten/1`, so a second run overwrote the first. The
  # tenant columns and `to:` types a human had worked out were replaced with
  # `:TODO_tenant_column` again, silently, with the exit code still 0.
  test "refuses to overwrite a plan that already exists", %{out: out} do
    assert {0, _first} = generate(["--output", out])
    finished = File.read!(out) <> "\n# finished by hand\n"
    File.write!(out, finished)

    assert {2, output} = generate(["--output", out])

    assert output =~ "never overwrites a plan"
    assert File.read!(out) == finished
  end

  # Sabotage: returned `{:ok, []}` for no candidates. The generator wrote a
  # plan with no `rewrite` blocks, which the DSL rejects with "declares no
  # rewrites" - a confusing second-hand error for a first-hand condition the
  # task can name itself.
  test "an application with no schemas writes nothing and says what is not reported", %{out: out} do
    assert {2, output} = generate(["--app", "logger", "--repo", "MyApp.Repo", "--output", out])

    assert output =~ "nothing to write a plan about"
    assert output =~ "{:array, MyType}"
    refute File.exists?(out)
  end

  test "an application that cannot be loaded is a usage error", %{out: out} do
    assert {2, output} = generate(["--app", "no_such_app_here", "--repo", "R", "--output", out])

    assert output =~ "not an application this project can load"
    refute File.exists?(out)
  end

  test "refuses to pick a repo when the app configures none", %{out: out} do
    assert {2, output} = generate(["--app", "logger", "--output", out])

    assert output =~ "--repo is required"
    assert output =~ "a plan names exactly one repo"
    refute File.exists?(out)
  end

  # Sabotage: defaulted to the first entry of `:ecto_repos` when several were
  # configured (`[repo | _]` for `[repo]`). The plan named one repo and the
  # operator ran it believing it covered the host, leaving a second database
  # entirely unmigrated. The zero-repo test above does not catch this - only a
  # host with several does, which is why this case is its own test.
  #
  # The env is set on a name no application owns, so nothing real is mutated
  # and the ambiguity is reported before any module of it is read.
  test "refuses to pick a repo when the app configures several", %{out: out} do
    Application.put_env(:ece_6ba_two_repos, :ecto_repos, [MyApp.PrimaryRepo, MyApp.LedgerRepo])
    on_exit(fn -> Application.delete_env(:ece_6ba_two_repos, :ecto_repos) end)

    assert {2, output} = generate(["--app", "ece_6ba_two_repos", "--output", out])

    assert output =~ "--repo is required"
    assert output =~ "MyApp.PrimaryRepo"
    assert output =~ "MyApp.LedgerRepo"
    assert output =~ "A host with several writes several plans"
    refute File.exists?(out)
  end

  # Sabotage: skipped the alias check. `--module my_app/plan.ex` was written
  # into the file as a `defmodule` name, producing source that cannot parse -
  # from an argument off the command line.
  test "--module that is not a module alias is a usage error", %{out: out} do
    assert {2, output} = generate(["--module", "my_app/plan.ex", "--output", out])

    assert output =~ "--module expects a module alias"
    refute File.exists?(out)
  end

  # Sabotage: accepted positional arguments and ignored them. `mix
  # encryptor.ecto.gen.plan MyApp.Plan` looked like it named the plan to write
  # and silently wrote the default one instead.
  test "takes no positional arguments, and says which verbs do", %{out: out} do
    assert {2, output} = generate(["MyApp.Plan", "--output", out])

    assert output =~ "takes no positional arguments"
    assert output =~ "mix encryptor.ecto.migrate"
  end

  test "an unknown flag is a usage error", %{out: out} do
    assert {2, output} = generate(["--mode", "write", "--output", out])

    assert output =~ "--mode"
  end

  defp generate(argv) do
    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(self(), {:exit_code, Plan.main(argv)}) end)
        send(self(), {:stdout, stdout})
      end)

    assert_received {:exit_code, code}
    assert_received {:stdout, stdout}

    {code, stdout <> stderr}
  end
end
