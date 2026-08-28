defmodule Encryptor.Ecto.Migration do
  @moduledoc """
  The compile-time DSL for a migration plan (ADR-0002 decision 2).

  A plan module names one repo and, per schema, the fields to rewrite and how
  the tenant is resolved for its rows:

      defmodule MyApp.Encryption.CloakMigration do
        use Encryptor.Ecto.Migration, repo: MyApp.Repo

        rewrite MyApp.Accounts.Customer do
          tenant_from :account_id

          field :tax_id, from: MyApp.Cloak.Encrypted.Binary, to: MyApp.Encrypted.Binary
          field :notes, from: MyApp.Cloak.Encrypted.String, to: MyApp.Encrypted.String
        end

        rewrite MyApp.Reference.Code do
          tenant :none
          field :value, from: MyApp.Cloak.Encrypted.Binary, to: MyApp.Encrypted.Binary
        end
      end

  The module compiles to a `t:Encryptor.Ecto.Migrator.Plan.t/0`, handed over by
  the `c:__plan__/0` callback this DSL defines. `Encryptor.Ecto.Migrator.run/2`
  and `verify/2` take the plan *module*, so a host names a file it can read.

  ## Why a plan is code

  Everything in a plan is code already: the `from` and `to` sides are type
  modules, and which fields are encrypted is exactly the kind of fact that
  should be reviewed in a diff, versioned with the schema it describes, and
  deleted in a named commit when the migration is finished. Configuration
  would make the most consequential operation this package performs invisible
  to code review - a change to which columns get rewritten, against live
  production data, arriving without a diff. So there is no config path here,
  and adding one is not a small convenience: it is the property being refused.

  ## The compile-time checks are the deliverable

  ADR-0002 decision 2 promises that a plan which would fail on row one fails
  at `mix compile`. Row one is against live production data, from a shell,
  usually late in a change window, and a typo discovered there has already
  cost the rehearsal. So every check that can be made against the schema and
  the modules is made while the plan module compiles, and each failure is a
  `CompileError` naming the schema and field it came from:

    * the schema is a real `Ecto.Schema`, and every `field` and `into:` names
      a field on it;
    * `tenant_from` names a real column, and a `tenant` module resolves;
    * every `from:` module can read the bytes - `resolve!/2` decides between
      `Encryptor.Ecto.Migrator.Source`, `Ecto.ParameterizedType` and
      `Ecto.Type` and refuses a module that is none of them;
    * every `to:` module can both load and dump at one consistent arity. The
      two sides are not symmetric even though the record states them in one
      clause: a `from:` module is the host's own legacy code and only has to
      *load*, while a `to:` module receives the rewritten bytes and must
      *dump* as well. A `to:` that cannot dump fails on row one just as
      loudly, and nothing else in this package would have caught it.

  `Code.ensure_compiled/1` precedes each of those, so a plan may name a module
  from its own application: the check waits for the parallel compiler rather
  than answering "not loaded" on a race it would lose intermittently.

  ## `from:` and `to:` may be the same module

  A field moving from `tenant: :none` to `tenant: :scope`, or gaining a
  `:context` pair, is a context change and therefore a full rewrite even
  though no type module changed. The migrator constructs both sides' params
  itself (ADR-0002 decision 3), so the plan expresses this by naming the same
  module on both sides; a migrator built on schema declarations could only
  ever express the type-module case. Nothing here rejects `from:` equal to
  `to:` for that reason.

  ## Adopting encryption on a plaintext column

  `into:` names a *different* target column, which is the backfill leg of the
  expand/backfill/contract dance a never-encrypted column needs (ADR-0002
  decision 8): plaintext lives in a text column, ciphertext must live in a
  binary one, and the DDL either side of the backfill is the host's own
  migration. Both columns are checked against the schema; which one is wider
  is not this package's business.

  ## What the legacy cipher does not prove

  A legacy stream cipher has no authentication tag, so a failed decrypt is not
  a signal: the bytes decrypt to *something*, and the migrator would
  re-encrypt that something into authenticated storage, permanently, and
  report it as a success (ADR-0004 decision 3). Two field options exist for
  that:

    * `source_authenticated: false` acknowledges it. The report then counts
      that field's rows `:migratable_unverified` rather than `:migratable`, in
      a dry run and in a verification alike, so no evidence claims
      verification that never happened; and the pass refuses to run in
      `--mode write` for that field unless `validate:` is declared with it.
    * `validate:` is a host-supplied `(term() -> boolean())` applied to the
      loaded plaintext before it is re-encrypted (decision 3b) - a tax
      identifier is nine digits, a serialized map parses, a kept legacy hash
      column recomputes (decision 3c). A row it rejects is `:undecryptable`,
      handled like any other failure. There is no built-in generic validator:
      this package cannot know what a valid value looks like, and a
      printable?/UTF-8? check would be reassurance rather than a control.

  ### Silence is allowed only where authentication is provable

  ADR-0004's proposed amendment of 2026-08-28 answers Q2. A field whose
  `from:` is one of this package's own vault-backed types needs no
  declaration, because the package that wrote those bytes authenticates them
  and `Encryptor.Ecto.Migrator.Source.vault_backed?/2` can prove it - that is
  the context-change case above, where `from:` and `to:` name the same module
  with different params. Every other `from:` is the host's own legacy reader:
  a cloak cipher module, a legacy `load/1`, an unknown `Source`. This
  package's correctness obligation on that format is nil (decision 1) and it
  cannot tell an AEAD cipher from a stream cipher by looking, so it asks - at
  `mix compile`, where the question is cheap - and such a field must declare
  `source_authenticated:` explicitly, `true` or `false`. `true` is not a
  capability this package checks; it is the host asserting that someone looked
  at the legacy cipher, in a line a reviewer sees in the diff.

  A host upgrading across this change sees its plan stop compiling, with a
  message naming the field and saying what to write.
  """

  alias Encryptor.Ecto.Migrator.Plan
  alias Encryptor.Ecto.Migrator.Source

  @typedoc """
  One field's rewrite.

  `:from` and `:to` are the modules the host writes. `:into` names a different
  target column for the backfill leg of an adoption migration, and is `nil`
  for the ordinary data-only case. `:source` is derived rather than written:
  it is what `Encryptor.Ecto.Migrator.Source.resolve!/2` decided about `:from`
  while the plan compiled, kept here because ADR-0004 decision 2 fixes that
  resolution as a compile-time step and re-deriving it at run time would put
  the decision back where the record took it from.

  `:source_authenticated` and `:validate` are ADR-0004 decision 3, and
  `:source_authenticated` is always present in the compiled spec even where
  the plan did not write it: an undeclared field is `true` only because the
  compile-time check proved it (see "What the legacy cipher does not prove"),
  so the engine reads one key rather than deciding provability again per row.
  """
  @type field_spec :: [
          from: module(),
          to: module(),
          into: atom() | nil,
          source: Source.resolved(),
          source_authenticated: boolean(),
          validate: (term() -> boolean()) | nil
        ]

  @typedoc "Where a compile-time failure came from, for the `CompileError`."
  @type meta :: [file: String.t(), line: non_neg_integer()]

  @doc """
  The compiled plan. Defined by `use Encryptor.Ecto.Migration`.
  """
  @callback __plan__() :: Plan.t()

  @use_options [:repo]

  # Host-written field options, in the order they are documented. Adding one
  # is meant to be this list plus a validating clause and nothing else, which
  # is how `source_authenticated:` and `validate:` arrived.
  @field_options [:from, :to, :into, :source_authenticated, :validate]

  # The macros below call back into this module through `unquote(__MODULE__)`.
  # The generated code runs inside the host's plan module, which has aliased
  # nothing of ours, and injecting an `alias` there to make the call read
  # shorter would be this DSL writing into a namespace that is not its own.

  @doc """
  Declares a plan module. Takes `repo:`, and nothing else yet.
  """
  defmacro __using__(opts) do
    meta = meta(__CALLER__)

    quote do
      @behaviour Encryptor.Ecto.Migration

      import Encryptor.Ecto.Migration, only: [rewrite: 2, tenant_from: 1, tenant: 1, field: 2]

      Module.register_attribute(__MODULE__, :encryptor_ecto_rewrites, accumulate: true)
      Module.put_attribute(__MODULE__, :encryptor_ecto_open, nil)

      Module.put_attribute(
        __MODULE__,
        :encryptor_ecto_repo,
        unquote(__MODULE__).__repo__!(unquote(opts), unquote(meta))
      )

      @before_compile Encryptor.Ecto.Migration
    end
  end

  @doc """
  Opens a rewrite of one schema. Its body declares a tenant strategy and one
  or more fields.
  """
  defmacro rewrite(schema, do: body) do
    meta = meta(__CALLER__)

    quote do
      unquote(__MODULE__).__open__(__MODULE__, unquote(schema), unquote(meta))
      unquote(body)
      unquote(__MODULE__).__close__(__MODULE__, unquote(meta))
    end
  end

  @doc """
  Declares that the tenant is read off the named column of each row.
  """
  defmacro tenant_from(column) do
    meta = meta(__CALLER__)

    quote do
      unquote(__MODULE__).__tenant__(
        __MODULE__,
        {:column, unquote(column)},
        unquote(meta)
      )
    end
  end

  @doc """
  Declares the tenant strategy: `:none` for a global field, or an
  `Encryptor.Ecto.TenantContext` module.
  """
  defmacro tenant(strategy) do
    meta = meta(__CALLER__)

    quote do
      unquote(__MODULE__).__tenant__(__MODULE__, unquote(strategy), unquote(meta))
    end
  end

  @doc """
  Declares one field to rewrite: `from:`, `to:`, and optionally `into:`,
  `source_authenticated:` and `validate:`.

  `source_authenticated:` is required rather than optional wherever the
  `from:` type is not one of this package's own - see "What the legacy cipher
  does not prove".
  """
  defmacro field(name, opts) do
    meta = meta(__CALLER__)

    quote do
      unquote(__MODULE__).__field__(__MODULE__, unquote(name), unquote(opts), unquote(meta))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    meta = meta(env)
    rewrites = env.module |> Module.get_attribute(:encryptor_ecto_rewrites) |> Enum.reverse()

    if rewrites == [] do
      raise_at!(meta, empty_plan_message(env.module))
    end

    plan =
      Macro.escape(%Plan{
        repo: Module.get_attribute(env.module, :encryptor_ecto_repo),
        rewrites: rewrites
      })

    quote do
      @impl Encryptor.Ecto.Migration
      def __plan__, do: unquote(plan)
    end
  end

  # -- the `use` options ----------------------------------------------------

  @doc false
  @spec __repo__!(keyword(), meta()) :: module()
  def __repo__!(opts, meta) do
    opts = assert_keyword!(opts, meta, "`use Encryptor.Ecto.Migration`")
    refuse_unknown!(Keyword.keys(opts), @use_options, meta, "`use Encryptor.Ecto.Migration`")

    case Keyword.fetch(opts, :repo) do
      {:ok, repo} when is_atom(repo) -> assert_repo!(repo, meta)
      {:ok, other} -> raise_at!(meta, not_a_module_message("repo:", other))
      :error -> raise_at!(meta, missing_repo_message())
    end
  end

  @spec assert_repo!(module(), meta()) :: module()
  defp assert_repo!(repo, meta) do
    if exports?(repo, :__adapter__, 0) do
      repo
    else
      raise_at!(meta, not_a_repo_message(repo))
    end
  end

  # -- the rewrite block ----------------------------------------------------

  @doc false
  @spec __open__(module(), module(), meta()) :: :ok
  def __open__(plan_module, schema, meta) do
    if open(plan_module), do: raise_at!(meta, nested_rewrite_message())

    unless is_atom(schema) and exports?(schema, :__schema__, 1) do
      raise_at!(meta, not_a_schema_message(schema))
    end

    if Enum.any?(rewrites(plan_module), &(&1.schema == schema)) do
      raise_at!(meta, duplicate_rewrite_message(schema))
    end

    put_open(plan_module, %{schema: schema, tenant: nil, fields: []})
  end

  @doc false
  @spec __close__(module(), meta()) :: :ok
  def __close__(plan_module, meta) do
    rewrite = open!(plan_module, meta, "rewrite")

    if rewrite.tenant == nil, do: raise_at!(meta, missing_tenant_message(rewrite.schema))
    if rewrite.fields == [], do: raise_at!(meta, empty_rewrite_message(rewrite.schema))

    Module.put_attribute(plan_module, :encryptor_ecto_rewrites, %{
      schema: rewrite.schema,
      tenant: rewrite.tenant,
      fields: Enum.reverse(rewrite.fields)
    })

    put_open(plan_module, nil)
  end

  # -- the tenant strategy --------------------------------------------------

  @doc false
  @spec __tenant__(module(), term(), meta()) :: :ok
  def __tenant__(plan_module, strategy, meta) do
    rewrite = open!(plan_module, meta, "tenant_from/1 and tenant/1")

    if rewrite.tenant, do: raise_at!(meta, duplicate_tenant_message(rewrite.schema))

    put_open(plan_module, %{rewrite | tenant: validate_tenant!(strategy, rewrite.schema, meta)})
  end

  @spec validate_tenant!(term(), module(), meta()) :: Plan.tenant()
  defp validate_tenant!({:column, column}, schema, meta) when is_atom(column) do
    unless column in schema_fields(schema) do
      raise_at!(meta, unknown_column_message(schema, column, "tenant_from"))
    end

    {:column, column}
  end

  defp validate_tenant!(:none, _schema, _meta), do: :none

  defp validate_tenant!(:scope, schema, meta) do
    raise_at!(meta, scope_tenant_message(schema))
  end

  defp validate_tenant!(module, schema, meta) when is_atom(module) do
    if exports?(module, :resolve, 2) do
      module
    else
      raise_at!(meta, not_a_resolver_message(schema, module))
    end
  end

  defp validate_tenant!(other, schema, meta) do
    raise_at!(meta, not_a_resolver_message(schema, other))
  end

  # -- one field ------------------------------------------------------------

  @doc false
  @spec __field__(module(), atom(), keyword(), meta()) :: :ok
  def __field__(plan_module, name, opts, meta) do
    rewrite = open!(plan_module, meta, "field/2")
    schema = rewrite.schema
    where = "#{inspect(schema)}.#{name}"

    unless is_atom(name) and name in schema_fields(schema) do
      raise_at!(meta, unknown_column_message(schema, name, "field"))
    end

    if List.keymember?(rewrite.fields, name, 0) do
      raise_at!(meta, duplicate_field_message(schema, name))
    end

    opts = assert_keyword!(opts, meta, where)
    refuse_unknown!(Keyword.keys(opts), @field_options, meta, where)

    from = required_module!(opts, :from, schema, name, meta)
    to = required_module!(opts, :to, schema, name, meta)
    source_opts = [schema: schema, field: name, file: meta[:file], line: meta[:line]]

    spec = [
      from: from,
      to: assert_target!(to, schema, name, meta),
      into: validate_into!(Keyword.get(opts, :into), schema, meta),
      source: Source.resolve!(from, source_opts),
      source_authenticated: source_authenticated!(opts, from, source_opts, meta),
      validate: validate_fun!(Keyword.get(opts, :validate), schema, name, meta)
    ]

    put_open(plan_module, %{rewrite | fields: [{name, spec} | rewrite.fields]})
  end

  @spec required_module!(keyword(), atom(), module(), atom(), meta()) :: module()
  defp required_module!(opts, key, schema, name, meta) do
    case Keyword.fetch(opts, key) do
      {:ok, module} when is_atom(module) and not is_nil(module) -> ensure_compiled(module)
      {:ok, other} -> raise_at!(meta, not_a_module_message("#{key}:", other))
      :error -> raise_at!(meta, missing_option_message(schema, name, key))
    end
  end

  @spec validate_into!(term(), module(), meta()) :: atom() | nil
  defp validate_into!(nil, _schema, _meta), do: nil

  defp validate_into!(column, schema, meta) when is_atom(column) do
    unless column in schema_fields(schema) do
      raise_at!(meta, unknown_column_message(schema, column, "into:"))
    end

    column
  end

  defp validate_into!(other, _schema, meta), do: raise_at!(meta, not_a_column_message(other))

  # ADR-0004 decision 3 and its proposed amendment of 2026-08-28 (Q2). Silence
  # compiles to `true` exactly where `Source.vault_backed?/2` proves it, and is
  # a `CompileError` naming the field everywhere else. The proof runs only when
  # the plan said nothing: a field that declared `true` has already answered
  # the question, and re-deriving it would let this package's own opinion
  # override the host's assertion.
  @spec source_authenticated!(keyword(), module(), Source.field_opts(), meta()) :: boolean()
  defp source_authenticated!(opts, from, source_opts, meta) do
    case Keyword.fetch(opts, :source_authenticated) do
      {:ok, declared} when is_boolean(declared) ->
        declared

      {:ok, other} ->
        raise_at!(meta, not_an_acknowledgement_message(source_opts, other))

      :error ->
        Source.vault_backed?(from, source_opts) or
          raise_at!(meta, undeclared_source_message(source_opts, from))
    end
  end

  # A validator is escaped into the compiled plan, so it has to be a remote
  # capture: `&MyApp.Encryption.Checks.tax_id?/1` survives into the plan
  # struct, while an anonymous function or a local capture does not exist by
  # the time the migrator runs. Refused here with that sentence rather than
  # left to `Macro.escape/1`, whose message is about quoting and not about
  # migrations.
  @spec validate_fun!(term(), module(), atom(), meta()) :: (term() -> boolean()) | nil
  defp validate_fun!(nil, _schema, _name, _meta), do: nil

  defp validate_fun!(fun, schema, name, meta) when is_function(fun, 1) do
    if Function.info(fun, :type) == {:type, :external} do
      fun
    else
      raise_at!(meta, local_validator_message(schema, name))
    end
  end

  defp validate_fun!(other, schema, name, meta),
    do: raise_at!(meta, not_a_validator_message(schema, name, other))

  # The `to:` half of ADR-0002 decision 2's type check. A target is called for
  # both halves of the round trip, at one arity: a module exporting `load/3`
  # but only `dump/1` is a `ParameterizedType` half-written, and the migrator
  # would discover which half on row one.
  @spec assert_target!(module(), module(), atom(), meta()) :: module()
  defp assert_target!(module, schema, name, meta) do
    cond do
      exports?(module, :load, 3) and exports?(module, :dump, 3) -> module
      exports?(module, :load, 1) and exports?(module, :dump, 1) -> module
      true -> raise_at!(meta, unwritable_target_message(schema, name, module))
    end
  end

  # -- shared mechanics -----------------------------------------------------

  @spec meta(Macro.Env.t()) :: meta()
  defp meta(env), do: [file: env.file, line: env.line]

  @spec open(module()) :: map() | nil
  defp open(plan_module), do: Module.get_attribute(plan_module, :encryptor_ecto_open)

  @spec open!(module(), meta(), String.t()) :: map()
  defp open!(plan_module, meta, what) do
    open(plan_module) || raise_at!(meta, outside_rewrite_message(what))
  end

  @spec put_open(module(), map() | nil) :: :ok
  defp put_open(plan_module, value),
    do: Module.put_attribute(plan_module, :encryptor_ecto_open, value)

  @spec rewrites(module()) :: [Plan.rewrite()]
  defp rewrites(plan_module),
    do: Module.get_attribute(plan_module, :encryptor_ecto_rewrites) || []

  @spec schema_fields(module()) :: [atom()]
  defp schema_fields(schema), do: schema.__schema__(:fields)

  # `Code.ensure_compiled/1` rather than `Code.ensure_loaded?/1`: a plan
  # routinely names modules from its own application, and inside a macro the
  # bare load check answers on whichever module the parallel compiler happens
  # to have finished. This one waits for it instead.
  @spec ensure_compiled(module()) :: module()
  defp ensure_compiled(module) do
    _ = Code.ensure_compiled(module)
    module
  end

  @spec exports?(module(), atom(), arity()) :: boolean()
  defp exports?(module, function, arity) when is_atom(module) do
    _ = ensure_compiled(module)
    function_exported?(module, function, arity)
  end

  defp exports?(_module, _function, _arity), do: false

  @spec assert_keyword!(term(), meta(), String.t()) :: keyword()
  defp assert_keyword!(opts, meta, where) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise_at!(meta, not_options_message(where, opts))
    end
  end

  @spec refuse_unknown!([atom()], [atom()], meta(), String.t()) :: :ok
  defp refuse_unknown!(given, known, meta, where) do
    case given -- known do
      [] -> :ok
      unknown -> raise_at!(meta, unknown_options_message(where, unknown, known))
    end
  end

  @spec raise_at!(meta(), String.t()) :: no_return()
  defp raise_at!(meta, description) do
    raise CompileError,
      description: description,
      file: Keyword.get(meta, :file, "nofile"),
      line: Keyword.get(meta, :line, 0)
  end

  # -- the messages ---------------------------------------------------------
  #
  # Every one of these names what the plan said and what to write instead: the
  # reader is someone who wrote a plan in a hurry, and the compiler is the
  # last place this migration is cheap to fix.

  defp missing_repo_message do
    "`use Encryptor.Ecto.Migration` requires `repo:`, naming the repo the " <>
      "rewritten rows live in: `use Encryptor.Ecto.Migration, repo: MyApp.Repo`. " <>
      "A plan names one repo (ADR-0002 decision 12); a host with several " <>
      "writes several plans."
  end

  defp not_a_repo_message(repo) do
    "`use Encryptor.Ecto.Migration` was given `repo: #{inspect(repo)}`, which " <>
      "is not an Ecto repo: it exports no `__adapter__/0`. Name the module " <>
      "that `use Ecto.Repo`, not the schema or the application."
  end

  defp not_a_module_message(key, value) do
    "#{key} expects a module, got #{inspect(value)}."
  end

  defp not_a_schema_message(schema) do
    "`rewrite #{inspect(schema)}` names something that is not an Ecto schema: " <>
      "it exports no `__schema__/1`. A rewrite names the schema module whose " <>
      "table holds the ciphertext columns."
  end

  defp duplicate_rewrite_message(schema) do
    "#{inspect(schema)} is rewritten twice in this plan. Merge the two blocks: " <>
      "one schema is one rewrite, and the migrator keys its checkpoint cursor " <>
      "by schema and field (ADR-0002 decision 6)."
  end

  defp nested_rewrite_message do
    "a `rewrite` block cannot contain another one. Close the first block " <>
      "before opening the next."
  end

  defp outside_rewrite_message(what) do
    "#{what} may only be called inside a `rewrite` block, which is what says " <>
      "which schema the declaration is about."
  end

  defp missing_tenant_message(schema) do
    "`rewrite #{inspect(schema)}` declares no tenant. Add `tenant_from " <>
      ":some_column` to read it off each row, `tenant :none` for a global " <>
      "field, or `tenant MyApp.SomeResolver`. There is no default: the " <>
      "migrator passes the tenant explicitly (ADR-0002 decision 3), and a " <>
      "guess would rewrite rows under the wrong key."
  end

  defp duplicate_tenant_message(schema) do
    "`rewrite #{inspect(schema)}` declares a tenant twice. One rewrite has " <>
      "one tenant strategy; split the schema into two plans if two are " <>
      "genuinely needed."
  end

  defp empty_rewrite_message(schema) do
    "`rewrite #{inspect(schema)}` declares no fields, so it would read and " <>
      "write nothing. Add a `field`, or delete the block."
  end

  defp empty_plan_message(plan_module) do
    "#{inspect(plan_module)} declares no rewrites, so running it would do " <>
      "nothing. Add a `rewrite`, or delete the plan module - a finished " <>
      "migration's plan is meant to be deleted in a named commit."
  end

  defp scope_tenant_message(schema) do
    "`rewrite #{inspect(schema)}` declares `tenant :scope`, which the " <>
      "migrator cannot honour: process scope is ambient state a pass run " <>
      "from a release command does not have, and reading the empty scope " <>
      "would rewrite every row under the wrong key. Use `tenant_from " <>
      ":some_column`, or name a resolver module."
  end

  defp not_a_resolver_message(schema, given) do
    "`rewrite #{inspect(schema)}` declares `tenant #{inspect(given)}`, which " <>
      "is neither `:none`, a column (`tenant_from :some_column`), nor a " <>
      "module implementing `Encryptor.Ecto.TenantContext`: it exports no " <>
      "`resolve/2`."
  end

  defp unknown_column_message(schema, column, what) do
    "#{what} names #{inspect(column)}, which is not a field of " <>
      "#{inspect(schema)}. Its fields are: #{inspect(schema_fields(schema))}."
  end

  defp not_a_column_message(given) do
    "`into:` expects a column name, got #{inspect(given)}."
  end

  defp duplicate_field_message(schema, name) do
    "#{inspect(schema)}.#{name} is declared twice in one rewrite. One field " <>
      "is rewritten once; a field that needs two passes needs two plans."
  end

  defp missing_option_message(schema, name, key) do
    "#{inspect(schema)}.#{name} declares no `#{key}:`. Every field names both " <>
      "sides of the rewrite: `from:` is whatever can already read these bytes " <>
      "in production, `to:` is the type the rows are being written into."
  end

  defp unwritable_target_message(schema, name, module) do
    "#{inspect(schema)}.#{name} names #{inspect(module)} as its `to:` type, " <>
      "but that module cannot write the rewritten bytes: it exports no " <>
      "matching `load`/`dump` pair, at arity 3 (`Ecto.ParameterizedType`) or " <>
      "arity 1 (`Ecto.Type`). Unlike `from:`, which only has to read, a `to:` " <>
      "module is called for both halves of the round trip."
  end

  defp undeclared_source_message(source_opts, from) do
    "#{field_at(source_opts)} declares no `source_authenticated:`, and its " <>
      "`from:` type #{inspect(from)} is not one of this package's own " <>
      "vault-backed types, so nothing here can prove that the bytes it reads " <>
      "are authenticated. Write `source_authenticated: true` if someone has " <>
      "checked that the legacy cipher authenticates - an AEAD cipher such as " <>
      "AES-GCM does - or `source_authenticated: false` if it does not, or if " <>
      "nobody knows. A stream cipher decrypts wrong bytes to something " <>
      "rather than failing, and the migrator would re-encrypt that something " <>
      "into authenticated storage and call it a success (ADR-0004 decision " <>
      "3). Declaring `false` counts that field's rows " <>
      "`:migratable_unverified` and needs a `validate:` before `--mode " <>
      "write` will run it."
  end

  defp not_an_acknowledgement_message(source_opts, given) do
    "#{field_at(source_opts)} declares `source_authenticated: #{inspect(given)}`. " <>
      "It takes `true` or `false` and nothing else: it is an acknowledgement " <>
      "about the legacy cipher, not a capability this package can measure."
  end

  defp not_a_validator_message(schema, name, given) do
    "#{inspect(schema)}.#{name} declares `validate: #{inspect(given)}`, which " <>
      "is not a one-argument function. `validate:` is the host's own check " <>
      "on the loaded plaintext (ADR-0004 decision 3b), applied before the " <>
      "value is re-encrypted: `validate: &MyApp.Encryption.Checks.tax_id?/1`."
  end

  defp local_validator_message(schema, name) do
    "#{inspect(schema)}.#{name} declares a `validate:` function that is not a " <>
      "remote capture. Name it as `&SomeModule.some_check/1`: the plan is a " <>
      "compiled data structure, and an anonymous function or a local capture " <>
      "cannot be carried into it."
  end

  defp field_at(source_opts) do
    "#{inspect(Keyword.get(source_opts, :schema))}.#{Keyword.get(source_opts, :field)}"
  end

  defp not_options_message(where, given) do
    "#{where} expects a keyword list of options, got #{inspect(given)}."
  end

  defp unknown_options_message(where, unknown, known) do
    "#{where} was given unknown #{plural("option", unknown)} " <>
      "#{inspect(unknown)}. Known options: #{inspect(known)}."
  end

  defp plural(word, [_one]), do: word
  defp plural(word, _many), do: word <> "s"
end
