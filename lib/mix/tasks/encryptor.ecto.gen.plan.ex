defmodule Mix.Tasks.Encryptor.Ecto.Gen.Plan do
  @shortdoc "Writes a migration plan skeleton for a human to finish"

  @moduledoc """
  Generates a `Encryptor.Ecto.Migration` plan skeleton from the host's schemas.

      mix encryptor.ecto.gen.plan [--app APP] [--repo REPO]
                                  [--module MODULE] [--output PATH]

  The generator loads the host's application, reads every Ecto schema in it,
  and emits one `rewrite` block per schema that has at least one field whose
  type is a module rather than a built-in Ecto type, with one `field` line per
  such field.

  ## The file it writes does not compile, and that is the feature

  ADR-0004 decision 7 fixes three behaviours that each read as a defect once,
  and this task implements them deliberately. All three come from the same
  place: a plan decides what happens to production rows, so the facts a
  generator cannot know are left visibly unanswered rather than guessed.

  | | What it does | Why |
  |---|---|---|
  | Tenant | Emits `tenant_from :TODO_tenant_column` | Which column identifies the tenant is a fact about the host's domain model that no generator can read off a schema, and guessing it re-encrypts every row under one tenant's key. `tenant_from` is checked against the schema at `mix compile` (ADR-0002 decision 2), so the wrong answer cannot reach a row. A skeleton that compiled would be a skeleton somebody ran |
  | Target type | Emits `to:` as a comment, never a value | The generator cannot know which type module a field is being rewritten into, and a half-guess produces a diff that looks reviewed |
  | Field list | Over-reports | Per ADR-0004 decision 1 this package tests for no other library's marker function - not `cloak_ecto`'s `__cloak__/0`, not any other - so a custom `Ecto.Type` of the host's that encrypts nothing is listed too. A false positive a human deletes is strictly better than a field nobody noticed |

  The generated file carries a comment saying all of this, because the person
  who runs `mix compile` next may not be the person who ran this task.

  ## What counts as a candidate

  A field is a candidate when its declared type is a module rather than one of
  Ecto's own types: a plain `Ecto.Type` module, or an `Ecto.ParameterizedType`
  (which is what `use Encryptor.Ecto.Binary` and `cloak_ecto`'s type modules
  both produce). Ecto's own type modules - `Ecto.Enum`, `Ecto.UUID` - are not
  candidates, which is a fact about which application a module belongs to
  rather than an inspection of its interface.

  Two limits are worth stating rather than discovering:

    * **Composite types are not candidates.** A field typed `{:array, MyType}`
      is skipped, because `from:` names a module that reads one field's bytes
      and the array's element type is not that module. Check such fields by
      hand.
    * **Embedded schemas are skipped.** A rewrite names a table, and an
      embedded schema has none.

  This package's own types are candidates like any other, which is correct
  rather than incidental: a field moving between tenant strategies is a full
  rewrite with `from:` and `to:` naming the same module (ADR-0002 decision 3).

  ## Flags

  | Flag | Default | |
  |---|---|---|
  | `--app APP` | the current Mix project's application | Which application's modules to read schemas from |
  | `--repo REPO` | the app's `:ecto_repos`, when it names exactly one | The repo the plan names. Unlike the tenant column this is a fact the host has already declared, so a single configured repo is read rather than guessed; anything else is a usage error |
  | `--module MODULE` | `<App>.Encryption.Migration` | The plan module to generate |
  | `--output PATH` | derived from `--module` under `lib/` | Where to write the file |

  ## Exit codes

  | | |
  |---|---|
  | `0` | The file was written; its path is printed |
  | `2` | Usage error; the host's application would not compile; no candidate field was found; the repo could not be resolved; or the output file already exists - the generator never overwrites a plan |

  ## No release equivalent, and that is acknowledged

  Every other verb in the family wraps a function on
  `Encryptor.Ecto.Migrator`, so a release can do everything a laptop can
  (ADR-0004 decision 6). This one cannot: reading `__schema__(:type, field)`
  needs the host's schema modules compiled and loaded, which a Mix task in the
  host's project has and a release command does not. ADR-0004 Q6 records that
  as stated rather than decided. It is the right trade here because this verb
  writes source into a working tree, which is not a thing a release does.
  """

  use Mix.Task

  alias Encryptor.Ecto.Migrator.CLI

  @switches [app: :string, repo: :string, module: :string, output: :string]
  @alias_pattern ~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/

  @impl Mix.Task
  def run(argv) do
    argv |> main() |> CLI.halt()
  end

  @doc false
  @spec main([String.t()]) :: 0 | 2
  def main(argv) do
    with {:ok, parsed} <- parse(argv),
         :ok <- CLI.boot(),
         {:ok, settings} <- settings(parsed),
         {:ok, found} <- found(settings),
         :ok <- unwritten(settings.output) do
      generate(settings, found)
    else
      {:error, message} -> CLI.usage_error(message)
    end
  end

  @doc """
  The schemas of `modules` that have at least one candidate field.

  Ordered by module name so that re-running the generator against an unchanged
  application produces an unchanged file.
  """
  @spec candidates([module()]) :: [{module(), [{atom(), module()}]}]
  def candidates(modules) do
    modules
    |> Enum.filter(&schema?/1)
    |> Enum.sort()
    |> Enum.map(fn schema -> {schema, schema_candidates(schema)} end)
    |> Enum.reject(fn {_schema, fields} -> fields == [] end)
  end

  @doc """
  The source of the plan skeleton, as it lands in the host's tree.
  """
  @spec source(module(), module(), [{module(), [{atom(), module()}]}]) :: String.t()
  def source(plan_module, repo, found) do
    """
    defmodule #{inspect(plan_module)} do
    #{preamble()}
      @moduledoc false

      use Encryptor.Ecto.Migration, repo: #{inspect(repo)}

    #{Enum.map_join(found, "\n", &rewrite_block/1)}end
    """
  end

  # -- the generated file ---------------------------------------------------
  #
  # The comment below is the deliverable of ADR-0004's consequence "`gen.plan`
  # produces a file that does not compile, on purpose. This will read as a bug
  # to somebody, at least once, and the generated file therefore carries a
  # comment saying why." It is addressed to whoever runs `mix compile` next,
  # who may not be whoever ran this task.

  @spec preamble() :: String.t()
  defp preamble do
    """
      # A migration plan skeleton, generated by `mix encryptor.ecto.gen.plan`.
      #
      # THIS FILE DOES NOT COMPILE YET. That is deliberate (ADR-0004 decision
      # 7), not a bug in the generator, and the three unfinished things below
      # are each a fact about your domain that no generator can read off a
      # schema. Finish them and delete this comment.
      #
      # 1. Every `tenant_from :TODO_tenant_column` names a column that does
      #    not exist, so the plan fails at `mix compile`. Replace each one
      #    with the column that says which tenant a row belongs to - or with
      #    `tenant :none` for a genuinely global field, or with
      #    `tenant MyApp.SomeResolver`. Guessing this wrong re-encrypts every
      #    row under one tenant's key, and a skeleton that compiled would be a
      #    skeleton somebody ran.
      #
      # 2. Every field's `to:` is a comment rather than a value. Which type
      #    module a field is being rewritten into is your decision; a
      #    half-guess produces a diff that looks reviewed.
      #
      # 3. This list over-reports. The generator finds fields whose type is a
      #    module rather than a built-in Ecto type, and deliberately tests for
      #    no other library's marker function, so a custom type of yours that
      #    encrypts nothing is listed here too. Delete the lines that do not
      #    belong - a false positive you delete beats a field nobody noticed.
      #
      # Those three are what the generator left out. They are not necessarily
      # every reason this file will not compile yet: `Encryptor.Ecto.Migration`
      # checks each field against the schema and against both type modules, and
      # its errors name the schema and the field. Read that module for the
      # whole field format, and read `mix help encryptor.ecto.migrate` for the
      # runbook. Rehearse with `--mode dry-run` before ever running
      # `--mode write`; a finished migration's plan is meant to be deleted in a
      # named commit.\
    """
  end

  @spec rewrite_block({module(), [{atom(), module()}]}) :: String.t()
  defp rewrite_block({schema, fields}) do
    """
      rewrite #{inspect(schema)} do
        tenant_from :TODO_tenant_column

    #{Enum.map_join(fields, "\n", &field_lines/1)}  end
    """
  end

  @spec field_lines({atom(), module()}) :: String.t()
  defp field_lines({name, from}) do
    """
        field :#{name}, from: #{inspect(from)}
        # to: name the type module :#{name} is rewritten into, then move it
        #     onto the line above as `to: MyApp.Encrypted.Binary`.
    """
  end

  # -- finding the candidates -----------------------------------------------

  @spec schema?(module()) :: boolean()
  defp schema?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) and
      is_binary(module.__schema__(:source))
  end

  @spec schema_candidates(module()) :: [{atom(), module()}]
  defp schema_candidates(schema) do
    schema.__schema__(:fields)
    |> Enum.map(fn name -> {name, from_module(schema.__schema__(:type, name))} end)
    |> Enum.reject(fn {_name, from} -> is_nil(from) end)
  end

  # The whole of the "is this field encrypted?" heuristic, and deliberately
  # the whole of it: ADR-0004 decision 1 refuses to test for `__cloak__/0` or
  # any other library's private marker, so this asks only whether the declared
  # type is a module the host wrote.
  @spec from_module(term()) :: module() | nil
  defp from_module({:parameterized, {module, _params}}), do: host_module(module)

  defp from_module(type) when is_atom(type) do
    if Ecto.Type.base?(type), do: nil, else: host_module(type)
  end

  defp from_module(_composite), do: nil

  @spec host_module(term()) :: module() | nil
  defp host_module(module) when is_atom(module) do
    _ = Code.ensure_loaded(module)

    if Application.get_application(module) == :ecto, do: nil, else: module
  end

  defp host_module(_other), do: nil

  # -- parsing and settings -------------------------------------------------

  @spec parse([String.t()]) :: {:ok, keyword()} | {:error, String.t()}
  defp parse(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {parsed, [], []} -> {:ok, parsed}
      {_parsed, [_ | _] = args, []} -> {:error, positional_message(args)}
      {_parsed, _args, invalid} -> {:error, invalid_message(invalid)}
    end
  end

  @spec settings(keyword()) :: {:ok, map()} | {:error, String.t()}
  defp settings(parsed) do
    app = String.to_atom(Keyword.get(parsed, :app, default_app()))

    with {:ok, repo} <- repo(parsed, app),
         {:ok, plan_module} <- plan_module(parsed) do
      output = Keyword.get_lazy(parsed, :output, fn -> default_output(plan_module) end)
      {:ok, %{app: app, repo: repo, module: plan_module, output: output}}
    end
  end

  @spec default_app() :: String.t()
  defp default_app, do: Mix.Project.config() |> Keyword.fetch!(:app) |> Atom.to_string()

  @spec found(map()) :: {:ok, [{module(), [{atom(), module()}]}]} | {:error, String.t()}
  defp found(%{app: app}) do
    case modules(app) do
      {:error, message} -> {:error, message}
      {:ok, modules} -> found_in(modules, app)
    end
  end

  @spec found_in([module()], atom()) ::
          {:ok, [{module(), [{atom(), module()}]}]} | {:error, String.t()}
  defp found_in(modules, app) do
    case candidates(modules) do
      [] -> {:error, no_candidates_message(app)}
      found -> {:ok, found}
    end
  end

  @spec modules(atom()) :: {:ok, [module()]} | {:error, String.t()}
  defp modules(app) do
    _ = Application.load(app)

    case :application.get_key(app, :modules) do
      {:ok, modules} -> {:ok, modules}
      :undefined -> {:error, unknown_app_message(app)}
    end
  end

  # A single configured repo is read rather than guessed: `:ecto_repos` is the
  # host's own declaration, checked against `__adapter__/0` when the plan
  # compiles, and visible on the plan's first line in review. Zero or several
  # is a question, and this task asks it instead of picking one.
  @spec repo(keyword(), atom()) :: {:ok, module()} | {:error, String.t()}
  defp repo(parsed, app) do
    case Keyword.fetch(parsed, :repo) do
      {:ok, name} -> alias_module(name, "--repo")
      :error -> configured_repo(app)
    end
  end

  @spec configured_repo(atom()) :: {:ok, module()} | {:error, String.t()}
  defp configured_repo(app) do
    _ = Application.load(app)

    case Application.get_env(app, :ecto_repos, []) do
      [repo] -> {:ok, repo}
      other -> {:error, ambiguous_repo_message(app, other)}
    end
  end

  @spec plan_module(keyword()) :: {:ok, module()} | {:error, String.t()}
  defp plan_module(parsed) do
    case Keyword.fetch(parsed, :module) do
      {:ok, name} -> alias_module(name, "--module")
      :error -> {:ok, default_module()}
    end
  end

  @doc "The plan module `--module` defaults to: `<App>.Encryption.Migration`."
  @spec default_module() :: module()
  def default_module do
    Module.concat([Macro.camelize(default_app()), "Encryption", "Migration"])
  end

  @spec alias_module(String.t(), String.t()) :: {:ok, module()} | {:error, String.t()}
  defp alias_module(name, flag) do
    stripped = strip_elixir(name)

    if stripped =~ @alias_pattern do
      {:ok, Module.concat([stripped])}
    else
      {:error, not_an_alias_message(flag, name)}
    end
  end

  @spec strip_elixir(String.t()) :: String.t()
  defp strip_elixir("Elixir." <> rest), do: rest
  defp strip_elixir(name), do: name

  @doc "Where `--output` defaults to for `plan_module`: its conventional path under `lib/`."
  @spec default_output(module()) :: String.t()
  def default_output(plan_module) do
    Path.join("lib", Macro.underscore(inspect(plan_module)) <> ".ex")
  end

  @spec unwritten(String.t()) :: :ok | {:error, String.t()}
  defp unwritten(output) do
    if File.exists?(output), do: {:error, already_written_message(output)}, else: :ok
  end

  @spec generate(map(), [{module(), [{atom(), module()}]}]) :: 0
  defp generate(settings, found) do
    File.mkdir_p!(Path.dirname(settings.output))
    File.write!(settings.output, source(settings.module, settings.repo, found))

    Mix.shell().info("* creating #{settings.output}")
    Mix.shell().info(summary(found))

    0
  end

  @spec summary([{module(), [{atom(), module()}]}]) :: String.t()
  defp summary(found) do
    fields = found |> Enum.map(fn {_schema, fields} -> length(fields) end) |> Enum.sum()

    "#{plural(fields, "candidate field")} across #{plural(length(found), "schema", "schemas")}. " <>
      "It does not compile yet: finish every `tenant_from` and every `to:`, and delete " <>
      "the fields that are not encrypted. The file says which is which."
  end

  @spec plural(non_neg_integer(), String.t(), String.t() | nil) :: String.t()
  defp plural(count, word, many \\ nil)
  defp plural(1, word, _many), do: "1 #{word}"
  defp plural(count, word, nil), do: "#{count} #{word}s"
  defp plural(count, _word, many), do: "#{count} #{many}"

  # -- the messages ---------------------------------------------------------

  @spec positional_message([String.t()]) :: String.t()
  defp positional_message(args) do
    "takes no positional arguments and was given #{Enum.join(args, " ")}. This verb " <>
      "writes the plan rather than reading one; name the module it writes with " <>
      "--module. The plan-taking verbs are `mix encryptor.ecto.migrate` and " <>
      "`mix encryptor.ecto.verify`."
  end

  @spec invalid_message([{String.t(), term()}]) :: String.t()
  defp invalid_message(invalid) do
    Enum.map_join(invalid, "\n", fn {flag, _value} ->
      "#{flag} is not a flag of this task, or was given a value of the wrong type."
    end)
  end

  @spec not_an_alias_message(String.t(), String.t()) :: String.t()
  defp not_an_alias_message(flag, given) do
    "#{flag} expects a module alias such as MyApp.Encryption.Migration, and cannot " <>
      "use #{inspect(given)}. The name is written into a file in your tree, so it has " <>
      "to be one the compiler will accept."
  end

  @spec unknown_app_message(atom()) :: String.t()
  defp unknown_app_message(app) do
    "#{inspect(app)} is not an application this project can load, so its schemas " <>
      "cannot be read. Pass --app with the application whose schemas you are " <>
      "migrating; it defaults to this project's own."
  end

  @spec ambiguous_repo_message(atom(), term()) :: String.t()
  defp ambiguous_repo_message(app, configured) do
    "--repo is required: #{inspect(app)} configures #{inspect(configured)} as its " <>
      ":ecto_repos, and a plan names exactly one repo (ADR-0002 decision 12). A host " <>
      "with several writes several plans, one per repo. Only a single configured repo " <>
      "is read without being asked for."
  end

  @spec no_candidates_message(atom()) :: String.t()
  defp no_candidates_message(app) do
    "no field of any schema in #{inspect(app)} has a module type, so there is nothing " <>
      "to write a plan about and no file was created. A plan with no rewrites does not " <>
      "compile either. If you expected fields here, check that --app names the " <>
      "application the schemas live in, and note that fields typed `{:array, MyType}` " <>
      "and fields of embedded schemas are not reported - check those by hand."
  end

  @spec already_written_message(String.t()) :: String.t()
  defp already_written_message(output) do
    "#{output} already exists, and the generator never overwrites a plan. A plan is " <>
      "finished by hand, so an overwrite would discard exactly the tenant columns and " <>
      "`to:` types somebody worked out. Pass --output to write elsewhere, or move the " <>
      "file you have."
  end
end
