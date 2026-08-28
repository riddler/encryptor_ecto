defmodule Encryptor.Ecto.Migrator.CLI do
  @moduledoc false

  # The grammar behind the mix task family (ADR-0004 decision 6), in one
  # module because the family is fixed and the four verbs have to agree about
  # what a flag means. Deliberately undocumented in ExDoc: decision 10 makes
  # the tasks' own `@moduledoc`s the reference page, and a second documented
  # module beside them would be a second place for the grammar to drift to.
  #
  # Two rules shape everything here.
  #
  #   * Every flag maps one-to-one onto an option of
  #     `Encryptor.Ecto.Migrator.run/2` or `verify/2`. A task adds no
  #     capability the library function lacks, because a release has no Mix
  #     and a capability reachable only from a developer's laptop is the
  #     opposite of the control it looks like.
  #   * A flag whose verb has no library option behind it is a usage error,
  #     not a silently ignored argument. `verify/2` takes `:sample` and
  #     `:prefix` and nothing else, so `mix encryptor.ecto.verify
  #     --only-tenant` refuses instead of pretending to narrow anything.
  #
  # Exit codes are the tasks' contract with a runbook step that says "check it
  # worked": 0 clean, 1 the pass ran and found something, 2 usage error or a
  # plan that will not compile. `halt/1` is how a Mix task sets one - Mix
  # itself exits 0 whatever a task returns, so the code goes through
  # `System.at_exit/1`.

  alias Encryptor.Ecto.Migrator
  alias Encryptor.Ecto.Migrator.Report

  @migrate_switches [
    mode: :string,
    batch_size: :integer,
    resume: :boolean,
    prefix: :string,
    checkpoint: :boolean,
    only: :string,
    only_tenant: [:string, :keep],
    except_tenant: [:string, :keep],
    on_error: :string
  ]

  @verify_switches [prefix: :string, sample: :string]

  @migrate_only_flags ~w(
    --mode --batch-size --resume --no-resume --checkpoint --no-checkpoint
    --only --only-tenant --except-tenant --on-error
  )

  @modes %{"dry-run" => :dry_run, "write" => :write}
  @on_errors %{"halt" => :halt, "continue" => :continue}

  @typedoc "A parsed invocation: the plan module and the option list it becomes."
  @type invocation :: {module(), keyword()}

  @doc """
  Compiles and starts the host application, or reports why it could not.

  A plan that will not compile arrives here, which is why the boot is a
  rescued call rather than a `@requirements` entry: `mix` would exit 1 on a
  compile error, and 1 is the code that means "the pass ran and found
  something".
  """
  @spec boot() :: :ok | {:error, String.t()}
  def boot do
    Mix.Task.run("app.start")
    :ok
  rescue
    exception in [Mix.Error, CompileError, SyntaxError] ->
      {:error, Exception.message(exception)}
  end

  @doc "Parses `mix encryptor.ecto.migrate`'s argv into `run/2`'s arguments."
  @spec parse_migrate([String.t()]) :: {:ok, invocation()} | {:error, String.t()}
  def parse_migrate(argv) do
    with {:ok, parsed, args} <- parse(argv, @migrate_switches),
         {:ok, plan} <- plan_module(args),
         {:ok, opts} <- migrate_opts(parsed) do
      {:ok, {plan, opts}}
    end
  end

  @doc "Parses `mix encryptor.ecto.verify`'s argv into `verify/2`'s arguments."
  @spec parse_verify([String.t()]) :: {:ok, invocation()} | {:error, String.t()}
  def parse_verify(argv) do
    with {:ok, parsed, args} <- parse(argv, @verify_switches),
         {:ok, plan} <- plan_module(args),
         {:ok, sample} <- sample(parsed),
         {:ok, prefix} <- prefix(parsed) do
      {:ok, {plan, sample ++ prefix}}
    end
  end

  @doc """
  Runs a pass, prints its report, and returns the exit code it earned.

  An `ArgumentError` is the library's "this run cannot start" arm - an unknown
  option, a plan module that is not one, a tenant filter against a rewrite
  with no tenant column, a missing checkpoint table. None of those is a
  finding about rows, so none of them is exit 1.
  """
  @spec run_pass((-> {:ok, Report.t()} | {:error, Report.t()})) :: 0 | 1 | 2
  def run_pass(pass) do
    case pass.() do
      {:ok, report} -> print_report(report, 0)
      {:error, report} -> print_report(report, 1)
    end
  rescue
    exception in ArgumentError -> usage_error(Exception.message(exception))
  end

  @doc "Prints a usage failure where a shell redirect can separate it, and returns 2."
  @spec usage_error(String.t()) :: 2
  def usage_error(message) do
    IO.puts(:stderr, message)
    2
  end

  @doc """
  Makes a Mix invocation exit with `code`.

  `System.at_exit/1` rather than `System.halt/1`: halting immediately can drop
  buffered output, and the report is the reason an operator ran the task.
  """
  @spec halt(0 | 1 | 2) :: :ok
  def halt(0), do: :ok
  def halt(code), do: System.at_exit(fn _status -> exit({:shutdown, code}) end)

  @doc """
  What a pass did, as an operator reads it.

  Counts come from `Report.classes/0` rather than from a list written here, so
  a class added to the report (ADR-0002 proposed amendment 2's
  `:migratable_unverified`) prints without this module being edited. A failure
  line carries the schema, the field, the primary key and the reason - never a
  value, never bytes.
  """
  @spec render(Report.t()) :: String.t()
  def render(%Report{} = report) do
    Enum.join(
      ["mode: #{report.mode}"] ++
        count_lines(report) ++
        ["concurrent: #{report.concurrent}", "failures: #{report.failure_count}"] ++
        failure_lines(report),
      "\n"
    )
  end

  # -- parsing --------------------------------------------------------------

  @spec parse([String.t()], keyword()) ::
          {:ok, keyword(), [String.t()]} | {:error, String.t()}
  defp parse(argv, switches) do
    case OptionParser.parse(argv, strict: switches) do
      {parsed, args, []} -> {:ok, parsed, args}
      {_parsed, _args, invalid} -> {:error, invalid_message(invalid, switches)}
    end
  end

  @spec invalid_message([{String.t(), term()}], keyword()) :: String.t()
  defp invalid_message(invalid, switches) do
    Enum.map_join(invalid, "\n", fn {flag, _value} -> one_invalid(flag, switches) end)
  end

  @spec one_invalid(String.t(), keyword()) :: String.t()
  defp one_invalid(flag, switches) do
    if switches == @verify_switches and flag in @migrate_only_flags do
      wrong_verb_message(flag)
    else
      "#{flag} is not a flag of this task, or was given a value of the wrong type."
    end
  end

  @spec wrong_verb_message(String.t()) :: String.t()
  defp wrong_verb_message(flag) do
    "#{flag} is a `mix encryptor.ecto.migrate` flag. `mix encryptor.ecto.verify` " <>
      "takes only --prefix and --sample, because `Encryptor.Ecto.Migrator.verify/2` " <>
      "takes only :prefix and :sample. Adding the flag here would give the task a " <>
      "capability the library function does not have, which the release path could " <>
      "not reproduce (ADR-0004 decision 6)."
  end

  @spec plan_module([String.t()]) :: {:ok, module()} | {:error, String.t()}
  defp plan_module([name]), do: {:ok, Module.concat([strip_elixir(name)])}

  defp plan_module([]) do
    {:error,
     "PLAN is required: the plan module to run, for example " <>
       "`mix encryptor.ecto.migrate MyApp.Encryption.CloakMigration --mode dry-run`. " <>
       "The plan is the unit of work (ADR-0002 decision 2); there is no flag that " <>
       "names a schema or a field instead."}
  end

  defp plan_module(many) do
    {:error, "expects exactly one PLAN, and was given #{length(many)}: #{Enum.join(many, " ")}"}
  end

  @spec strip_elixir(String.t()) :: String.t()
  defp strip_elixir("Elixir." <> rest), do: rest
  defp strip_elixir(name), do: name

  # -- migrate options ------------------------------------------------------

  @spec migrate_opts(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  defp migrate_opts(parsed) do
    with {:ok, mode} <- mode(parsed),
         {:ok, rest} <- optional_migrate_opts(parsed),
         :ok <- resumable(rest) do
      {:ok, [{:mode, mode} | rest]}
    end
  end

  @spec optional_migrate_opts(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  defp optional_migrate_opts(parsed) do
    with {:ok, batch_size} <- batch_size(parsed),
         {:ok, prefix} <- prefix(parsed),
         {:ok, checkpoint} <- checkpoint(parsed),
         {:ok, on_error} <- enum_opt(parsed, :on_error, @on_errors),
         {:ok, only} <- only(parsed) do
      {:ok,
       batch_size ++ resume(parsed) ++ prefix ++ checkpoint ++ on_error ++ only ++ tenants(parsed)}
    end
  end

  @spec mode(keyword()) :: {:ok, Migrator.mode()} | {:error, String.t()}
  defp mode(parsed) do
    case enum_opt(parsed, :mode, @modes) do
      {:ok, []} -> {:error, missing_mode_message()}
      {:ok, [mode: mode]} -> {:ok, mode}
      {:error, message} -> {:error, message}
    end
  end

  @spec missing_mode_message() :: String.t()
  defp missing_mode_message do
    "--mode is required and has no default: `--mode dry-run` rehearses the pass and " <>
      "writes nothing, `--mode write` performs it (ADR-0002 decision 7). A default of " <>
      "dry-run trains an operator to add a flag they stop reading, and a default of " <>
      "write puts an irreversible pass one typo away."
  end

  @spec enum_opt(keyword(), atom(), %{String.t() => atom()}) ::
          {:ok, keyword()} | {:error, String.t()}
  defp enum_opt(parsed, key, mapping) do
    case Keyword.fetch(parsed, key) do
      :error ->
        {:ok, []}

      {:ok, value} ->
        case Map.fetch(mapping, value) do
          {:ok, mapped} -> {:ok, [{key, mapped}]}
          :error -> {:error, enum_message(key, value, mapping)}
        end
    end
  end

  @spec enum_message(atom(), String.t(), %{String.t() => atom()}) :: String.t()
  defp enum_message(key, value, mapping) do
    "--#{dashed(key)} expects one of #{Enum.join(Map.keys(mapping), "|")}, got #{inspect(value)}"
  end

  @spec batch_size(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  defp batch_size(parsed) do
    case Keyword.fetch(parsed, :batch_size) do
      :error -> {:ok, []}
      {:ok, rows} when rows > 0 -> {:ok, [batch_size: rows]}
      {:ok, rows} -> {:error, "--batch-size expects a positive integer, got #{rows}"}
    end
  end

  @spec resume(keyword()) :: keyword()
  defp resume(parsed) do
    case Keyword.fetch(parsed, :resume) do
      :error -> []
      {:ok, resume?} -> [resume: resume?]
    end
  end

  @spec prefix(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  defp prefix(parsed) do
    case Keyword.fetch(parsed, :prefix) do
      :error -> {:ok, []}
      {:ok, ""} -> {:error, "--prefix expects a schema prefix; omit it for the repo's default"}
      {:ok, prefix} -> {:ok, [prefix: prefix]}
    end
  end

  @spec checkpoint(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  defp checkpoint(parsed) do
    case Keyword.fetch(parsed, :checkpoint) do
      :error -> {:ok, []}
      {:ok, false} -> {:ok, [checkpoint: :none]}
      {:ok, true} -> {:error, checkpoint_message()}
    end
  end

  @spec checkpoint_message() :: String.t()
  defp checkpoint_message do
    "--checkpoint is not a flag: the checkpoint table is used by default, and " <>
      "--no-checkpoint is how a host that will not add the table runs " <>
      "(`checkpoint: :none`, every run a full scan)."
  end

  @spec resumable(keyword()) :: :ok | {:error, String.t()}
  defp resumable(opts) do
    if Keyword.get(opts, :resume) == true and Keyword.get(opts, :checkpoint) == :none do
      {:error,
       "--resume and --no-checkpoint together are a request with no meaning: there is " <>
         "no checkpoint to resume from. Drop one of them."}
    else
      :ok
    end
  end

  @spec tenants(keyword()) :: keyword()
  defp tenants(parsed) do
    keep(:only_tenants, Keyword.get_values(parsed, :only_tenant)) ++
      keep(:except_tenants, Keyword.get_values(parsed, :except_tenant))
  end

  @spec keep(atom(), [String.t()]) :: keyword()
  defp keep(_key, []), do: []
  defp keep(key, values), do: [{key, values}]

  @spec only(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  defp only(parsed) do
    case Keyword.fetch(parsed, :only) do
      :error -> {:ok, []}
      {:ok, spec} -> spec |> only_pairs() |> group_only()
    end
  end

  @spec only_pairs(String.t()) :: {:ok, [{module(), atom()}]} | {:error, String.t()}
  defp only_pairs(spec) do
    spec
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn pair, {:ok, acc} ->
      case String.split(pair, ":") do
        [schema, field] when schema != "" and field != "" ->
          {:cont, {:ok, acc ++ [{Module.concat([strip_elixir(schema)]), String.to_atom(field)}]}}

        _malformed ->
          {:halt, {:error, only_message(pair)}}
      end
    end)
  end

  @spec only_message(String.t()) :: String.t()
  defp only_message(pair) do
    "--only expects Schema:field pairs separated by commas, for example " <>
      "`--only MyApp.Card:pan,MyApp.Card:notes`, and cannot read #{inspect(pair)}"
  end

  @spec group_only({:ok, [{module(), atom()}]} | {:error, String.t()}) ::
          {:ok, keyword()} | {:error, String.t()}
  defp group_only({:error, message}), do: {:error, message}
  defp group_only({:ok, []}), do: {:ok, []}

  defp group_only({:ok, pairs}) do
    grouped =
      pairs
      |> Enum.reduce([], fn {schema, field}, acc ->
        Keyword.update(acc, schema, [field], &(&1 ++ [field]))
      end)
      |> Enum.reverse()

    {:ok, [only: grouped]}
  end

  @spec sample(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  defp sample(parsed) do
    case Keyword.fetch(parsed, :sample) do
      :error -> {:ok, []}
      {:ok, "all"} -> {:ok, [sample: :all]}
      {:ok, rows} -> parse_sample(rows)
    end
  end

  @spec parse_sample(String.t()) :: {:ok, keyword()} | {:error, String.t()}
  defp parse_sample(rows) do
    case Integer.parse(rows) do
      {count, ""} when count > 0 -> {:ok, [sample: count]}
      _other -> {:error, "--sample expects `all` or a positive integer, got #{inspect(rows)}"}
    end
  end

  @spec dashed(atom()) :: String.t()
  defp dashed(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  # -- rendering ------------------------------------------------------------

  @spec count_lines(Report.t()) :: [String.t()]
  defp count_lines(report) do
    Enum.map(Report.classes(), fn class ->
      "#{class}: #{Map.get(report.counts, class, 0)}"
    end)
  end

  @spec failure_lines(Report.t()) :: [String.t()]
  defp failure_lines(%Report{failures: []}), do: []

  defp failure_lines(%Report{} = report) do
    lines =
      Enum.map(report.failures, fn failure ->
        "  #{inspect(failure.schema)}.#{failure.field} id=#{inspect(failure.id)} " <>
          "reason=#{inspect(failure.reason)}"
      end)

    lines ++ elided(report)
  end

  @spec elided(Report.t()) :: [String.t()]
  defp elided(%Report{failures: shown, failure_count: total}) when total > length(shown) do
    ["  ... #{total - length(shown)} further failures not listed"]
  end

  defp elided(%Report{}), do: []

  @spec print_report(Report.t(), 0 | 1) :: 0 | 1
  defp print_report(report, code) do
    report |> render() |> IO.puts()
    code
  end
end
