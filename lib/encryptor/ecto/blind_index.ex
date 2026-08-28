defmodule Encryptor.Ecto.BlindIndex do
  @moduledoc """
  Declares a keyed blind index on an encrypted field (ADR-0003 decisions 4,
  3c and 6's declaration half).

  A blind index stores, in a second column beside an encrypted one, a
  deterministic keyed fingerprint of the plaintext, so that equality on
  plaintext becomes equality on fingerprint. `blind_index/3` is where a host
  says that a column has one, and what it is:

      defmodule MyApp.Accounts.Customer do
        use Ecto.Schema
        import Encryptor.Ecto.BlindIndex

        schema "customers" do
          field :merchant_id, :string

          field :email, MyApp.Encrypted.String
          field :email_index, :binary
          blind_index :email, :email_index, normalize: :email

          field :phone, MyApp.Encrypted.String
          field :phone_index, :binary
          blind_index :phone, :phone_index, normalize: :digits
        end
      end

  The index column is an ordinary column the host declares in its own
  migration and its own schema (decision 5). This package writes no
  migrations, adds no fields, and hooks no `Repo` callbacks. What the
  declaration does is put the index's normalization and its key derivation in
  exactly one place, so that the changeset helper that writes the column and
  the query helper that reads it cannot disagree about either.

  ## Options

  | Option | Default | Meaning |
  |---|---|---|
  | `:name` | the index column's name | The `index_name` component of the HKDF `info` string (decision 2) |
  | `:scope` | `:tenant` | `:tenant` or `:global` key derivation (decision 3) |
  | `:normalize` | `:none` | What the HMAC is computed over (decision 4) |
  | `:bits` | `256` | Stored width; `64`/`128`/`192` truncate the HMAC |
  | `:slow` | `false` | `true` runs Argon2id before the HMAC |
  | `:version` | `1` | Participates in the derivation, so a bump is a real rotation (decision 7) |

  `:normalize` is the option to read before any of the others.
  `Encryptor.Ecto.BlindIndex.Normalizer` documents the set and says, at the
  option rather than in a rotation appendix, that normalization is lossy and
  directional and that changing it invalidates every stored value in the
  column.

  `:bits` and `:slow` are accepted, checked and carried here; what they *do*
  to a computed value is decision 6's option half and is not implemented yet.
  A declaration written today with `bits: 64` therefore stores a full-width
  value until that lands, which is why nothing reads `:bits` at a call site in
  the meantime.

  ## Two indexes over one field

  A field may declare more than one index - decision 3d's per-tenant and
  global pair, or decision 7's rotation pair - and they are distinct because
  their `index_name`s are. The default `:name` is **the index column's** name
  rather than the source field's, so two indexes over one field are distinct
  without the host writing anything:

      field :email, MyApp.Encrypted.String
      field :email_index, :binary
      field :email_v2_index, :binary
      blind_index :email, :email_index
      blind_index :email, :email_v2_index, version: 2

  Decision 6 tables the default as "the column name" and the record uses
  "column" for both the source and the index column. The reading taken here is
  the one that makes decision 2's "`index_name` distinguishes two indexes over
  the same column" true: a default taken from the source field would give
  every index on one field the same `index_name`, which is the collapse the
  component exists to prevent.

  ## The two compile-time errors

  Both are decision 3c's, and both are deliberate.

  **A `tenant: :none` field must write its `:scope`.** `scope: :global` is the
  only possibility on a field that has no tenant, and declaring nothing is an
  error rather than a silent fallback to it. The reviewer reading that schema
  line is the person who needs to know that the column is cross-tenant
  correlatable and survives a tenant shred, and silence is exactly what a
  reviewer does not see. Declaring `scope: :tenant` on such a field is the
  other half of the same error (open question Q4): a global ciphertext with a
  per-tenant index is an incoherent pair, and it stays an error until somebody
  brings the case.

  **An index on a field this package does not encrypt is an error.** The
  derivation reads the encrypted field's frozen `Ecto.ParameterizedType`
  params for the declared table and column that reach the HKDF `info` string,
  so a source that is a plain `:string` field, or no field at all, has nothing
  to derive from.

  Three further conditions are refused at compile time as well. They are not
  in the record, and they are declaration hygiene rather than decisions: the
  index column must be a field on the schema, since nothing can write a column
  that is not one; and two declarations may not share a `{source, column}`
  pair or an `index_name`, since either collapses two indexes the design keeps
  distinct onto one column or one key.

  All of them are raised from an `@after_compile` hook rather than at the
  declaration, because that is the first moment the schema's own field list is
  readable - a `blind_index` line may legitimately be written above the
  `field` it indexes.

  ## Reading a declaration

  `Encryptor.Ecto.BlindIndex.Declaration` is the read surface: `list/1` and
  `list/2` enumerate a schema's indexes, `fetch!/3` resolves one, and
  `derivation!/1` and `normalize!/2` turn it into the two things computing an
  index value needs. `Encryptor.Ecto.BlindIndex.Derivation` performs the key
  derivation itself, through the vault.
  """

  alias Encryptor.Ecto.BlindIndex.Declaration

  @registered :encryptor_ecto_blind_index_registered
  @accumulated :encryptor_ecto_blind_indexes

  @doc """
  Declares a blind index on `source`, stored in `column`.

  Used inside a schema module - conventionally inside the `schema/2` block,
  beside the fields it names, though anywhere in the module body works. See
  the moduledoc for the options and for what is refused at compile time.
  """
  @spec blind_index(atom(), atom(), keyword()) :: Macro.t()
  defmacro blind_index(source, column, opts \\ []) do
    # Named by an unquoted module atom rather than written out, for the reason
    # `Encryptor.Ecto.Binary`'s own macro gives: nothing injected into a host
    # schema's namespace on its way past.
    impl = __MODULE__

    quote do
      unquote(impl).__register__(__MODULE__)

      @encryptor_ecto_blind_indexes unquote(impl).__declaration__(
                                      __MODULE__,
                                      unquote(source),
                                      unquote(column),
                                      unquote(opts)
                                    )
    end
  end

  @doc false
  @spec __declaration__(module(), term(), term(), term()) :: Declaration.t()
  def __declaration__(schema, source, column, opts),
    do: Declaration.new!(schema, source, column, opts)

  @doc false
  @spec __register__(module()) :: :ok
  def __register__(module) do
    if Module.get_attribute(module, @registered) do
      :ok
    else
      Module.put_attribute(module, @registered, true)
      Module.register_attribute(module, @accumulated, accumulate: true)
      Module.put_attribute(module, :before_compile, __MODULE__)
      Module.put_attribute(module, :after_compile, __MODULE__)
      :ok
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    declarations =
      env.module
      |> Module.get_attribute(@accumulated)
      |> Enum.reverse()
      |> Macro.escape()

    quote do
      @doc false
      @spec __encryptor_ecto_blind_indexes__() :: [
              Encryptor.Ecto.BlindIndex.Declaration.t()
            ]
      def __encryptor_ecto_blind_indexes__, do: unquote(declarations)
    end
  end

  @doc false
  @spec __after_compile__(Macro.Env.t(), binary()) :: :ok
  def __after_compile__(env, _bytecode), do: validate!(env.module)

  @doc """
  Checks every blind index declared on a schema, raising on the first fault.

  Called for a schema automatically as it compiles; public because a host that
  builds schemas some other way still wants the check, and because a check
  that can only be observed by compiling something is a check nobody can test.
  """
  @spec validate!(module()) :: :ok
  def validate!(schema) when is_atom(schema) do
    declarations = Declaration.list(schema)

    unless declarations == [] or ecto_schema?(schema) do
      raise ArgumentError,
            "#{inspect(schema)} declares blind indexes but is not an Ecto schema. " <>
              "blind_index/3 reads the encrypted field's declared context from the " <>
              "schema, and there is none to read here."
    end

    Enum.each(declarations, &validate_declaration!/1)
    validate_distinct!(schema, declarations, & &1.name, "an index name")
    validate_distinct!(schema, declarations, &{&1.source, &1.column}, "a source field and column")

    :ok
  end

  # -- one declaration ------------------------------------------------------

  @spec validate_declaration!(Declaration.t()) :: :ok
  defp validate_declaration!(declaration) do
    params = source_params!(declaration)
    validate_index_column!(declaration)
    validate_scope!(declaration, params.tenant)
  end

  @spec source_params!(Declaration.t()) :: map()
  defp source_params!(declaration) do
    case Declaration.field_params(declaration) do
      {:ok, params} ->
        params

      {:error, :missing_field} ->
        raise ArgumentError,
              at(declaration) <>
                ", but #{inspect(declaration.source)} is not a field on this schema. " <>
                "The source of an index is the encrypted field it fingerprints, not " <>
                "the column the fingerprint is stored in."

      {:error, :not_encrypted} ->
        raise ArgumentError,
              at(declaration) <>
                ", but #{inspect(declaration.source)} is not a field this package " <>
                "encrypts (ADR-0003 decision 3c). An index derives its key from the " <>
                "declared table and column the encrypted field froze, and an ordinary " <>
                "field has none - a keyed fingerprint of a column that is already " <>
                "readable would also be protecting nothing."
    end
  end

  # Not in ADR-0003: declaration hygiene. Nothing can write a column that is
  # not a field, and the failure without this check arrives at the first write
  # naming Ecto's own error rather than the schema line.
  @spec validate_index_column!(Declaration.t()) :: :ok
  defp validate_index_column!(declaration) do
    case declaration.schema.__schema__(:type, declaration.column) do
      nil ->
        raise ArgumentError,
              at(declaration) <>
                ", but #{inspect(declaration.column)} is not a field on this schema. " <>
                "The index column is an ordinary column the host declares in its own " <>
                "migration and its own schema: add `field #{inspect(declaration.column)}, " <>
                ":binary` beside the encrypted field."

      {:parameterized, {type, _params}} ->
        if encrypted_type?(type) do
          raise ArgumentError,
                at(declaration) <>
                  ", but #{inspect(declaration.column)} is itself an encrypted field. " <>
                  "An index value is a deterministic fingerprint stored in the clear " <>
                  "beside the ciphertext; encrypting it would make it unqueryable, " <>
                  "which is the whole point of the column."
        end

        :ok

      _ordinary_type ->
        :ok
    end
  end

  @spec validate_scope!(Declaration.t(), term()) :: :ok
  defp validate_scope!(%Declaration{scope_declared?: false} = declaration, :none) do
    raise ArgumentError,
          at(declaration) <>
            " with no :scope, on a field declared tenant: :none (ADR-0003 " <>
            "decision 3c). scope: :global is the only possibility here and it still " <>
            "has to be written: the reviewer reading this line is the person who " <>
            "needs to know that this column's equality structure spans every tenant " <>
            "and survives a tenant shred, and silence is exactly what a reviewer " <>
            "does not see."
  end

  defp validate_scope!(%Declaration{scope: :tenant} = declaration, :none) do
    raise ArgumentError,
          at(declaration) <>
            " with scope: :tenant, on a field declared tenant: :none (ADR-0003 " <>
            "decision 3c, open question Q4). A global ciphertext with a per-tenant " <>
            "index is an incoherent pair: there is no tenant to key the index with, " <>
            "and the rows the index would answer for belong to no tenant. Write " <>
            "scope: :global, or give the field a tenant."
  end

  defp validate_scope!(_declaration, _tenant), do: :ok

  # -- the set --------------------------------------------------------------

  @spec validate_distinct!(module(), [Declaration.t()], (Declaration.t() -> term()), String.t()) ::
          :ok
  defp validate_distinct!(schema, declarations, key, what) do
    duplicates =
      declarations
      |> Enum.group_by(key)
      |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
      |> Enum.sort_by(fn {key, _group} -> inspect(key) end)

    case duplicates do
      [] ->
        :ok

      [{_key, [declaration | _rest]} | _more] ->
        raise ArgumentError,
              "#{inspect(schema)} declares more than one blind index sharing #{what}, " <>
                "starting at #{inspect(declaration.source)}, " <>
                "#{inspect(declaration.column)}. Two indexes over one field are " <>
                "distinct only if their index names are, and two declarations writing " <>
                "one column overwrite each other; give each its own column and, where " <>
                "the default does not already, its own :name."
    end
  end

  # -- shared ---------------------------------------------------------------

  # The schema is the module this check runs inside the `@after_compile` of,
  # so it is loaded by the time the question is asked and `ensure_loaded?/1`
  # answers it without waiting on anything.
  @spec ecto_schema?(module()) :: boolean()
  defp ecto_schema?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1)

  # A *type* module is a different module in the same compilation unit, so it
  # needs `Code.ensure_compiled/1` for the reason
  # `Encryptor.Ecto.BlindIndex.Declaration` gives at its own predicate: under
  # the parallel compiler `ensure_loaded?/1` would answer a question about
  # scheduling rather than about the module.
  @spec encrypted_type?(module()) :: boolean()
  defp encrypted_type?(type) when is_atom(type),
    do:
      match?({:module, _module}, Code.ensure_compiled(type)) and
        function_exported?(type, :__encryptor_ecto__, 1)

  @spec at(Declaration.t()) :: String.t()
  defp at(declaration) do
    "#{inspect(declaration.schema)} declares blind_index " <>
      "#{inspect(declaration.source)}, #{inspect(declaration.column)}"
  end
end
