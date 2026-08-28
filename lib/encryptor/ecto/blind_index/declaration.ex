defmodule Encryptor.Ecto.BlindIndex.Declaration do
  @moduledoc """
  One `blind_index/3` declaration, and the single source of truth the write
  side and the read side both read (ADR-0003 decisions 4, 5 and 6's
  declaration half).

  `Encryptor.Ecto.BlindIndex.blind_index/3` builds one of these while the
  schema module compiles and stores it on the module. Everything that computes
  an index value afterwards - the changeset helper, the query helper, a host
  building its own query - resolves the declaration from the schema and reads
  its normalization and its key derivation from here. That is what makes
  decision 5's promise structural rather than a review preference: two helpers
  that read one declaration cannot disagree about what the index is.

  ## What is stored, and what is resolved later

  The struct holds the declaration verbatim - the source field, the index
  column, and the six options - plus the schema it was written in. What it
  does *not* hold is anything read from the encrypted field: the declared
  table and column that reach the HKDF `info` string come from the field's
  frozen `Ecto.ParameterizedType` params (ADR-0001 decision 4, acceptance
  amendment 5), and `derivation!/1` reads them at the point of use rather than
  copying them here. A copy would be a second place for the declared context
  to live, and the whole point of freezing it is that there is one.

  ## `:scope`, and why `:scope_declared?` is carried

  Decision 3a defaults a tenant-capable field's index to `scope: :tenant`, so
  `:scope` is always resolved on the struct and a reader never has to apply a
  default. Decision 3c then makes *silence* an error on a `tenant: :none`
  field, which is a fact about what the reviewer saw written rather than about
  the resolved value - `scope: :global` written and `scope: :global` inferred
  are the same derivation and a different schema line. `:scope_declared?`
  carries that distinction to the compile-time check, and is why the check can
  refuse a declaration whose resolved scope would have been correct anyway.

  ## Which operation an index computation is

  `Encryptor.Ecto.BlindIndex.Derivation.selector!/3` takes the
  `Encryptor.Ecto.TenantContext` operation from its caller, because ADR-0003
  does not say which of `:dump`/`:load` an index computation is. This package
  answers it here, at the seam where the answer becomes observable to a host
  resolver: **a write-side computation asks with `:dump` and a read-side
  computation asks with `:load`**, matching what the encrypted field itself
  would be doing at the same moment. A host whose resolver answers differently
  for reads and writes - a reporting job with a `:load` tenant it does not
  have on `:dump` is ADR-0001's own example - gets the answer it would expect
  from the ordinary encryption path. The ruling is recorded for the acceptance
  reading rather than assumed settled.
  """

  alias Encryptor.Ecto.BlindIndex.Derivation
  alias Encryptor.Ecto.BlindIndex.Normalizer

  @options [:name, :scope, :normalize, :bits, :slow, :version]
  @scopes [:tenant, :global]
  @widths [64, 128, 192, 256]

  @enforce_keys [:schema, :source, :column, :name]
  defstruct [
    :schema,
    :source,
    :column,
    :name,
    scope: :tenant,
    scope_declared?: false,
    normalize: :none,
    bits: 256,
    slow: false,
    version: 1
  ]

  @typedoc """
  One declared index.

  `:source` is the encrypted field being indexed and `:column` is the ordinary
  field the index value is stored in. `:name` is the `index_name` component of
  the HKDF `info` string (decision 2), always a binary by the time it is here.
  """
  @type t :: %__MODULE__{
          schema: module(),
          source: atom(),
          column: atom(),
          name: String.t(),
          scope: Derivation.scope(),
          scope_declared?: boolean(),
          normalize: Normalizer.t(),
          bits: 64 | 128 | 192 | 256,
          slow: boolean(),
          version: pos_integer()
        }

  @typedoc "Why a declaration cannot be resolved against its schema."
  @type resolution_error :: :missing_field | :not_encrypted

  @doc """
  Builds one declaration, checking its options where the host wrote them.

      iex> Encryptor.Ecto.BlindIndex.Declaration.new!(
      ...>   MyApp.Customer, :email, :email_index, normalize: :email)
      %Encryptor.Ecto.BlindIndex.Declaration{
        schema: MyApp.Customer,
        source: :email,
        column: :email_index,
        name: "email_index",
        scope: :tenant,
        scope_declared?: false,
        normalize: :email,
        bits: 256,
        slow: false,
        version: 1
      }

  `:name` defaults to **the index column's** name, not the source field's.
  Decision 6 tables the default as "the column name" and the record uses
  "column" for both, so the reading is chosen here: `index_name` exists to
  distinguish two indexes over one source column (decision 2), and a default
  taken from the source would make every index on one field derive the same
  key - which is the one thing the component is there to prevent. Two indexes
  over one field are therefore distinct by default, and a host that wants them
  to share nothing but the field writes nothing extra.

      iex> Encryptor.Ecto.BlindIndex.Declaration.new!(
      ...>   MyApp.Customer, :email, :email_short, bits: 64).name
      "email_short"

  An unknown option is refused where it is written rather than ignored, and so
  is a value outside an option's set.

      iex> Encryptor.Ecto.BlindIndex.Declaration.new!(
      ...>   MyApp.Customer, :email, :email_index, normalise: :email)
      ** (ArgumentError) MyApp.Customer declares blind_index :email, :email_index with unknown options: [:normalise]. Known options: [:name, :scope, :normalize, :bits, :slow, :version].

  Every argument but the schema is typed as `t:term/0` rather than as what it
  has to be. This is the boundary the macro hands a host's literal words
  across, and a spec that promised they were already an atom and a keyword
  list would make the checks below unreachable to a static analyser and, worse,
  imply they had been made somewhere else.
  """
  @spec new!(module(), term(), term(), term()) :: t()
  def new!(schema, source, column, opts \\ []) do
    at = at(schema, source, column)

    unless is_atom(source) and is_atom(column) do
      raise ArgumentError,
            "#{inspect(schema)} declares a blind index whose source field and index " <>
              "column must both be atoms naming fields on the schema."
    end

    opts = validate_options!(at, opts)

    %__MODULE__{
      schema: schema,
      source: source,
      column: column,
      name: name!(at, opts, column),
      scope: Keyword.get(opts, :scope, :tenant),
      scope_declared?: Keyword.has_key?(opts, :scope),
      normalize: Keyword.get(opts, :normalize, :none),
      bits: Keyword.get(opts, :bits, 256),
      slow: Keyword.get(opts, :slow, false),
      version: Keyword.get(opts, :version, 1)
    }
  end

  @doc """
  Every index declared on a schema, in declaration order.

  A module that declares none - or is not a schema at all - has no indexes
  rather than an error, so a caller sweeping a host's modules does not have to
  ask twice.

      iex> Encryptor.Ecto.BlindIndex.Declaration.list(Encryptor.Ecto.TestSchemas.Customer)
      ...> |> Enum.map(& &1.column)
      [:email_index, :email_short_index, :phone_index]

      iex> Encryptor.Ecto.BlindIndex.Declaration.list(Encryptor.Ecto.TestSchemas.Card)
      []
  """
  @spec list(module()) :: [t()]
  def list(schema) when is_atom(schema) do
    if declares?(schema), do: schema.__encryptor_ecto_blind_indexes__(), else: []
  end

  @doc """
  Every index declared over one source field.

      iex> Encryptor.Ecto.BlindIndex.Declaration.list(
      ...>   Encryptor.Ecto.TestSchemas.Customer, :email)
      ...> |> Enum.map(& &1.name)
      ["email_index", "email_short_index"]
  """
  @spec list(module(), atom()) :: [t()]
  def list(schema, source) when is_atom(schema) and is_atom(source),
    do: Enum.filter(list(schema), &(&1.source == source))

  @doc """
  The declaration for one `{source, column}` pair.

      iex> {:ok, declaration} =
      ...>   Encryptor.Ecto.BlindIndex.Declaration.fetch(
      ...>     Encryptor.Ecto.TestSchemas.Customer, :email, :email_index)
      iex> declaration.normalize
      :email

      iex> Encryptor.Ecto.BlindIndex.Declaration.fetch(
      ...>   Encryptor.Ecto.TestSchemas.Customer, :email, :nowhere)
      :error
  """
  @spec fetch(module(), atom(), atom()) :: {:ok, t()} | :error
  def fetch(schema, source, column)
      when is_atom(schema) and is_atom(source) and is_atom(column) do
    case Enum.find(list(schema), &(&1.source == source and &1.column == column)) do
      nil -> :error
      declaration -> {:ok, declaration}
    end
  end

  @doc """
  The same, raising with what *is* declared when nothing matches.

  The message lists the schema's declarations because the overwhelmingly
  likely cause is a helper naming a column that is spelled differently at the
  declaration, and a reader who can see both spellings at once is done.
  """
  @spec fetch!(module(), atom(), atom()) :: t()
  def fetch!(schema, source, column) do
    case fetch(schema, source, column) do
      {:ok, declaration} -> declaration
      :error -> raise ArgumentError, undeclared_message(schema, source, column)
    end
  end

  @doc """
  The encrypted field's frozen parameters, read from the schema.

  Returns `{:error, :missing_field}` when the source names no field and
  `{:error, :not_encrypted}` when it names one this package does not encrypt.
  Both are the compile-time check's material; `field_params!/1` is the arm for
  a caller that has already been through that check.
  """
  @spec field_params(t()) :: {:ok, Derivation.field_params()} | {:error, resolution_error()}
  def field_params(%__MODULE__{schema: schema, source: source}) do
    case schema.__schema__(:type, source) do
      {:parameterized, {type, params}} ->
        if encrypted?(type), do: {:ok, params}, else: {:error, :not_encrypted}

      nil ->
        {:error, :missing_field}

      _ordinary_type ->
        {:error, :not_encrypted}
    end
  end

  @doc """
  The same, raising for a caller past the compile-time check.

      iex> Encryptor.Ecto.BlindIndex.Declaration.fetch!(
      ...>   Encryptor.Ecto.TestSchemas.Customer, :email, :email_index)
      ...> |> Encryptor.Ecto.BlindIndex.Declaration.field_params!()
      ...> |> Map.take([:table, :column, :tenant])
      %{table: "customers", column: "email", tenant: :scope}
  """
  @spec field_params!(t()) :: Derivation.field_params()
  def field_params!(%__MODULE__{} = declaration) do
    case field_params(declaration) do
      {:ok, params} -> params
      {:error, reason} -> raise ArgumentError, unresolvable_message(declaration, reason)
    end
  end

  @doc """
  The derivation identity this declaration keys under.

  The table and column come from the encrypted field's frozen params rather
  than from the declaration, so an index derives under the same declared
  context the field encrypts under, and a physical rename moves neither.

      iex> Encryptor.Ecto.BlindIndex.Declaration.fetch!(
      ...>   Encryptor.Ecto.TestSchemas.Customer, :email, :email_index)
      ...> |> Encryptor.Ecto.BlindIndex.Declaration.derivation!()
      ...> |> Encryptor.Ecto.BlindIndex.Derivation.info()
      "encryptor_ecto/blind_index/v1|customers|email|email_index|1"
  """
  @spec derivation!(t()) :: Derivation.t()
  def derivation!(%__MODULE__{} = declaration) do
    params = field_params!(declaration)

    Derivation.new!(
      table: params.table,
      column: params.column,
      index_name: declaration.name,
      version: declaration.version,
      scope: declaration.scope
    )
  end

  @doc """
  Normalizes one value under this declaration's normalizer.

  The declared table and column reach the failure from the encrypted field, so
  a host normalizer that misbehaves produces an exception naming the schema
  line rather than the call site.

      iex> Encryptor.Ecto.BlindIndex.Declaration.fetch!(
      ...>   Encryptor.Ecto.TestSchemas.Customer, :email, :email_index)
      ...> |> Encryptor.Ecto.BlindIndex.Declaration.normalize!(" Bob@Example.COM ")
      "bob@example.com"
  """
  @spec normalize!(t(), binary()) :: binary()
  def normalize!(%__MODULE__{} = declaration, value) do
    params = field_params!(declaration)

    Normalizer.normalize!(declaration.normalize, value,
      table: params.table,
      column: params.column,
      index_name: declaration.name
    )
  end

  @doc """
  Whether a module carries blind index declarations.

  `Code.ensure_loaded?/1` before `function_exported?/2` for the reason
  `Encryptor.Ecto.Declarations` gives at its own use of the pair: the bare
  export check answers false for a module that is merely not loaded yet, and a
  check whose answer depends on load order passes in the suite that would have
  caught the mistake.
  """
  @spec declares?(module()) :: boolean()
  def declares?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :__encryptor_ecto_blind_indexes__, 0)
  end

  # -- option checking ------------------------------------------------------

  @spec validate_options!(String.t(), term()) :: keyword()
  defp validate_options!(at, opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "#{at} expects a keyword list of options."
    end

    case Keyword.keys(opts) -- @options do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "#{at} with unknown options: #{inspect(unknown)}. " <>
                "Known options: #{inspect(@options)}."
    end

    Enum.each(opts, &validate_option!(at, &1))

    opts
  end

  @spec validate_option!(String.t(), {atom(), term()}) :: :ok
  defp validate_option!(at, {:scope, scope}) when scope not in @scopes,
    do: refuse!(at, :scope, scope, "one of #{inspect(@scopes)}")

  defp validate_option!(at, {:bits, bits}) when bits not in @widths,
    do: refuse!(at, :bits, bits, "one of #{inspect(@widths)}")

  defp validate_option!(at, {:slow, slow}) when not is_boolean(slow),
    do: refuse!(at, :slow, slow, "a boolean")

  defp validate_option!(at, {:normalize, normalize}) do
    if Normalizer.valid?(normalize) do
      :ok
    else
      refuse!(
        at,
        :normalize,
        normalize,
        "one of #{inspect(Normalizer.builtin())}, or a {module, function} pair"
      )
    end
  end

  defp validate_option!(at, {:version, version}) do
    if is_integer(version) and version > 0 do
      :ok
    else
      refuse!(at, :version, version, "a positive integer")
    end
  end

  defp validate_option!(_at, {_option, _value}), do: :ok

  # The `info` string's own separator, refused here for the reason
  # `Encryptor.Ecto.BlindIndex.Derivation` refuses it one layer down: a
  # component that can spell a separator can spell another index's identity.
  # It is caught here as well so the message names the schema line rather than
  # a constraint one call further in.
  @spec name!(String.t(), keyword(), atom()) :: String.t()
  defp name!(at, opts, column) do
    case Keyword.get(opts, :name, column) do
      name when is_atom(name) and name not in [nil, true, false] ->
        name!(at, [name: Atom.to_string(name)], column)

      name when is_binary(name) and name != "" ->
        if String.contains?(name, "|") do
          refuse!(at, :name, name, ~s(a name carrying no "|", the info string's separator))
        end

        name

      name ->
        refuse!(at, :name, name, "a non-empty atom or binary")
    end
  end

  # `Code.ensure_compiled/1` rather than `Encryptor.Ecto.Declarations`'
  # `Code.ensure_loaded?/1`, because this predicate runs inside a schema's own
  # compilation as well as at runtime. Under the parallel compiler the type
  # module named by a schema in the same compilation unit is routinely not
  # loaded yet, and `ensure_loaded?/1` answers false rather than waiting for
  # it - which would turn "is this one of ours" into a question about
  # scheduling. `ensure_compiled/1` waits, and at runtime the two agree.
  @spec encrypted?(module()) :: boolean()
  defp encrypted?(type) when is_atom(type) do
    match?({:module, _module}, Code.ensure_compiled(type)) and
      function_exported?(type, :__encryptor_ecto__, 1)
  end

  # -- messages -------------------------------------------------------------

  # `term()` rather than `atom()` for the same reason `new!/4`'s own spec is
  # open: this renders what the host wrote, before anything has checked it,
  # and a narrower spec would let a static analyser conclude the checks that
  # follow the first call to it are unreachable.
  @spec at(module(), term(), term()) :: String.t()
  defp at(schema, source, column),
    do: "#{inspect(schema)} declares blind_index #{inspect(source)}, #{inspect(column)}"

  @spec refuse!(String.t(), atom(), term(), String.t()) :: no_return()
  defp refuse!(at, option, value, expected) do
    raise ArgumentError,
          "#{at} with #{inspect(option)}: #{inspect(value)}, which is not #{expected}."
  end

  defp undeclared_message(schema, source, column) do
    """
    #{inspect(schema)} declares no blind index on #{inspect(source)} stored in \
    #{inspect(column)}.

    Declared on this schema:
    #{declared_list(schema)}
    """
  end

  defp declared_list(schema) do
    case list(schema) do
      [] ->
        "  (none)"

      declarations ->
        Enum.map_join(
          declarations,
          "\n",
          &"  blind_index #{inspect(&1.source)}, #{inspect(&1.column)}"
        )
    end
  end

  defp unresolvable_message(declaration, :missing_field) do
    "#{at(declaration.schema, declaration.source, declaration.column)}, but " <>
      "#{inspect(declaration.source)} is not a field on that schema."
  end

  defp unresolvable_message(declaration, :not_encrypted) do
    "#{at(declaration.schema, declaration.source, declaration.column)}, but " <>
      "#{inspect(declaration.source)} is not a field this package encrypts."
  end
end
