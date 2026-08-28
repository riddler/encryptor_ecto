defmodule Encryptor.Ecto.Migrator.Source do
  @moduledoc """
  How the migrator reads the pre-migration value of a column.

  ADR-0002's typespecs name this behaviour with a single callback; ADR-0004
  decision 2 fixes what satisfies it and how a plan names one. A plan's
  `from:` accepts three things:

  | `from:` value | Meaning |
  |---|---|
  | A module implementing `Ecto.Type` (arity-1 `load/1`) | Adapted by `Encryptor.Ecto.Migrator.Source.EctoType`. This is every `cloak_ecto` type module and every hand-rolled one |
  | A module implementing `Ecto.ParameterizedType` (arity-3 `load/3`) | Adapted by `Encryptor.Ecto.Migrator.Source.EctoType`, with params constructed by the migrator |
  | A module implementing this behaviour | Used as-is. `Encryptor.Ecto.Migrator.Source.Plaintext` is the one this package ships |

  `resolve!/2` decides between them **once, while the plan module is
  compiling**, and `load/3` is what the engine calls per row. Nothing here
  branches on `cloak_ecto`, imports it, or recognizes one of its messages:
  the module doing the legacy load is the module the host has been running in
  production, and this package's correctness obligation on the legacy format
  is exactly nil (ADR-0004 decision 1).

  ## Why the resolution is a compile-time step

  ADR-0002 decision 2 promises that a plan which would fail on row one fails
  at `mix compile`. A `from:` module that can read nothing is exactly that
  kind of plan, and discovering it on row one of a nine-hundred-thousand-row
  pass - against live production data, from a shell - is the failure mode the
  promise exists to remove. `resolve!/2` is the source half of it, and it
  raises `CompileError` naming the field rather than returning an error tuple,
  because its caller is a macro and its reader is a compiler.

  ## Why a failure here is data rather than an exception

  ADR-0001 decision 6 makes the *types* raise, which is right for application
  code and wrong for a migrator that must classify a failure and keep a
  report. At this boundary a failed read is `{:error, reason}`, the migrator
  classifies the row `:undecryptable`, and ADR-0002 decision 11's default is
  still to halt the pass. That conversion is the adapter's job and is
  described in `Encryptor.Ecto.Migrator.Source.EctoType`; a module
  implementing this behaviour directly is contracted to return the tuple
  itself, and a raise from one is a contract violation this module
  deliberately does *not* launder.

  ## The deferred-decryption unwrap

  A zero-arity function returned by a source is invoked **once**, and its
  result is the plaintext. Deferred decryption is a real convention among
  legacy types - `cloak_ecto`'s `:closure` option is exactly it - and a source
  that returned a closure would otherwise have the migrator re-encrypt the
  *function* rather than the value. The rule is generic to this contract
  rather than cloak handling, which is why it lives in `load/3` and not in the
  adapter. Invoked once means once: a closure that returns another closure
  yields that closure as the value, because a loop here would be this package
  guessing at a convention nobody wrote down.

  ## The redaction rule, at this boundary

  The unwrapped value is never logged, inspected, or put in an error (ADR-0002
  decision 11, ADR-0001 decision 6). Two consequences are visible in the code
  below and are deliberate:

    * a result that is neither `{:ok, term}` nor `{:error, reason}` becomes
      `{:error, :invalid_source_result}` rather than falling through to a
      `CaseClauseError`, whose message would carry the unmatched term - which
      is to say, the plaintext;
    * a rescued exception is reported as `{:error, {:raised, Module}}`, the
      raising module's name and nothing else. A foreign legacy type's
      exception is a struct this package cannot inspect for secrets and whose
      `Inspect` implementation it does not control, so the message and the
      struct both stay out of the reason. The cost is real - an operator
      reading a report learns which module failed but not what it said - and
      it is the same trade `Encryptor.Ecto.Error` already makes by redacting
      on shape rather than on provenance.
  """

  alias Encryptor.Ecto.Migrator.Source.EctoType

  @typedoc """
  What the migrator hands a source for one row.

  ADR-0002 decision 3: the migrator works below the schema layer and supplies
  context explicitly, so the params are constructed per field rather than read
  off a schema declaration.
  """
  @type params :: map()

  @typedoc """
  A `from:` module resolved to a source and the params the resolution fixed.

  The second element is merged over the migrator's per-field params by
  `load/3`, which is how the adapter learns which module it is adapting
  without the plan carrying that detail into every row.
  """
  @type resolved :: {module(), params()}

  @typedoc "The identifying options `resolve!/2` reads to build its message."
  @type field_opts :: [
          schema: module(),
          field: atom(),
          file: String.t(),
          line: non_neg_integer()
        ]

  @doc """
  Reads the pre-migration value of one column of one row.

  Returns `{:ok, plaintext}` or `{:error, reason}`; it does not raise for a
  value it cannot read.
  """
  @callback load(binary(), params()) :: {:ok, term()} | {:error, term()}

  @doc """
  Decides which source reads a `from:` module, at plan compile time.

  Raises `CompileError` naming the field when the module cannot be loaded, or
  when it implements neither this behaviour, `Ecto.ParameterizedType`, nor
  `Ecto.Type`.

      iex> alias Encryptor.Ecto.Migrator.Source
      iex> Source.resolve!(Source.Plaintext, schema: My.Schema, field: :notes)
      {Encryptor.Ecto.Migrator.Source.Plaintext, %{}}
  """
  @spec resolve!(module(), field_opts()) :: resolved()
  def resolve!(module, field_opts) when is_atom(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        compile_error!(unloadable_message(module, field_opts), field_opts)

      source?(module) ->
        {module, %{}}

      function_exported?(module, :load, 3) ->
        {EctoType, %{source_module: module, source_arity: 3}}

      function_exported?(module, :load, 1) ->
        {EctoType, %{source_module: module, source_arity: 1}}

      true ->
        compile_error!(unreadable_message(module, field_opts), field_opts)
    end
  end

  @doc """
  Calls a resolved source for one row, and unwraps a deferred decryption.

  The params the resolution fixed are merged over the migrator's per-field
  params, so an adapter's own keys win over a field key of the same name.
  """
  @spec load(resolved(), binary(), params()) :: {:ok, term()} | {:error, term()}
  def load({source, source_params}, value, params) do
    case source.load(value, Map.merge(params, source_params)) do
      {:ok, loaded} -> unwrap(loaded)
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_source_result}
    end
  end

  @doc """
  Invokes a zero-arity function returned by a source, once, and returns its
  result as the plaintext. Any other term is already the plaintext.

  A raise from the closure is converted the way the adapter converts a raise
  from a load: the closure *is* the deferred half of the load it came from,
  so a legacy type that defers its decrypt must not be able to halt the pass
  in a way the same type decrypting eagerly would not.
  """
  @spec unwrap(term()) :: {:ok, term()} | {:error, term()}
  def unwrap(value) when is_function(value, 0) do
    {:ok, value.()}
  rescue
    exception -> {:error, {:raised, exception.__struct__}}
  end

  def unwrap(value), do: {:ok, value}

  @spec source?(module()) :: boolean()
  defp source?(module) do
    __MODULE__ in List.flatten(Keyword.get_values(module.module_info(:attributes), :behaviour))
  end

  @spec compile_error!(String.t(), field_opts()) :: no_return()
  defp compile_error!(description, field_opts) do
    raise CompileError,
      description: description,
      file: Keyword.get(field_opts, :file, "nofile"),
      line: Keyword.get(field_opts, :line, 0)
  end

  defp unloadable_message(module, field_opts) do
    "#{describe(field_opts)} names #{inspect(module)} as its `from:` source, " <>
      "but that module could not be loaded. A plan names modules the host " <>
      "already runs; check the spelling and that the library defining it is " <>
      "still in the tree for the migration window."
  end

  defp unreadable_message(module, field_opts) do
    "#{describe(field_opts)} names #{inspect(module)} as its `from:` source, " <>
      "but that module implements neither #{inspect(__MODULE__)} nor an Ecto " <>
      "type: it exports no `load/1` (`Ecto.Type`) and no `load/3` " <>
      "(`Ecto.ParameterizedType`). The `from:` module is whatever can already " <>
      "read these bytes in production."
  end

  defp describe(field_opts) do
    case {Keyword.get(field_opts, :schema), Keyword.get(field_opts, :field)} do
      {nil, nil} -> "a plan field"
      {nil, field} -> "the plan field #{inspect(field)}"
      {schema, nil} -> "a plan field of #{inspect(schema)}"
      {schema, field} -> "#{inspect(schema)}.#{field}"
    end
  end
end
