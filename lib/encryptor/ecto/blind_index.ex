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
  derivation itself, through the vault, and
  `Encryptor.Ecto.BlindIndex.Value` is the one place the two meet.

  ## The two helpers, and no magic (decision 5)

  A declaration on its own writes nothing and reads nothing. `put_index/3`
  computes the column on the write side and `where_eq/3` constrains it on the
  read side, and both read their configuration from the declaration above, so
  they cannot disagree about normalization or key derivation:

      changeset
      |> cast(attrs, [:email])
      |> put_index(:email, :email_index)

      from(c in Customer) |> where_eq(:email, "bob@example.com")

  `put_index/3` does not recompute an index whose source field was not
  changed, and writes `nil` when the source is set to `nil` (decision 8): a
  `NULL` plaintext beside a non-`NULL` index would leak that a value exists.

  `where_eq/3` expands to an equality on the index column and to nothing else.
  There is no `where_like`, no `where_gt`, no ordering helper, and no operator
  argument that could be made to generate one - decision 9 makes equality the
  whole surface permanently, and an operator parameter is how a package ships
  the rest of it by accident. `where_eq_candidates/3` is the same constraint
  under the weaker contract a truncated index answers under (decision 6), and
  `compute/3` is the value itself, for a host building its own query.

  ### Both raise on a missing tenant, `where_eq/3` included

  This is the sharpest requirement in the record. A `scope: :tenant` index
  computed outside tenant scope raises `Encryptor.Ecto.MissingTenantError`
  identically to ADR-0001 decision 5c, on the read side as well as the write
  side - so a query *built* outside tenant scope raises where it is built,
  rather than being executed and matching nothing. A blind-index query that
  silently matches nothing is the worst failure this feature can have, because
  it looks exactly like "the record does not exist".

  ### Naming the index when a field has more than one

  `put_index/3` always names its column. `where_eq/3`, `where_eq_candidates/3`
  and `compute/3` take the source field, which resolves on their own when the
  field has exactly one index and is ambiguous when it has the two that
  decision 3d's per-tenant/global pair and decision 7's rotation pair both
  produce. Each therefore has a four-argument form naming the index column:

      from(c in Customer) |> where_eq(:email, :email_v2_index, "bob@example.com")

  which is what decision 7 step 4 - "switch `where_eq/3` to the new version" -
  is written with, since during the rotation window both versions are declared
  and neither is the one the source field means. The three-argument form
  refuses an ambiguous field by name rather than picking; the arities are the
  record's and the disambiguating form is this package's addition to them.

  ### Two things the record does not settle, carried here

  **ADR-0003 Q3, a query outliving its scope.** `where_eq/3` binds the tenant
  at *build* time, which is the fail-loud choice and the one decision 5 makes.
  The consequence is that the returned `Ecto.Query` carries a tenant-specific
  constant that is invisible in the struct and wrong if the struct is reused
  in another tenant's scope - it would then match nothing, which is the
  failure mode the build-time raise exists to prevent, arriving by a different
  road. Nothing here stamps the query or checks at execute: that is a guard
  the record leaves open, and adding one unasked would put a tenant identifier
  into a struct hosts serialize. It is recorded rather than resolved.

  **A tenant key rotation is not the rotation this record describes.**
  Decision 7's two-column dance covers a change to a *declaration* - a
  version, a normalizer, a width. `encryptor`'s ADR-0003 amendment A decision 7
  consults only the current encryption key, so rotating a tenant's key changes
  every index key under it without any declaration changing, and every value
  already stored under the superseded key stops being derivable. During that
  window `where_eq/3` matches nothing and raises nothing. ADR-0003 does not
  describe that case and this package does not invent a behaviour for it:
  `where_eq_candidates/3` is decision 6's truncation surface and is *not* a
  multi-key candidate surface. A host rotating a tenant key must reindex that
  tenant's index columns, and what the package should do about it is an open
  question for the record rather than a default chosen here.
  """

  alias Ecto.Changeset
  alias Encryptor.Ecto.BlindIndex.Declaration
  alias Encryptor.Ecto.BlindIndex.Value

  require Ecto.Query

  @registered :encryptor_ecto_blind_index_registered
  @accumulated :encryptor_ecto_blind_indexes

  # Decision 6's `:bits` default, and the only width `where_eq/3` accepts. The
  # option half of decision 6 - what a narrower width does to a computed value
  # - is not implemented here; this constant is only what tells the two read
  # helpers apart, which the record already says they are told apart by.
  @full_width 256

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

  # -- the write side (decisions 5 and 8) -----------------------------------

  @doc """
  Computes and puts the index column for a changed source field.

  Reads the cast plaintext, applies the field's normalizer, computes the HMAC
  under the field's index key, and puts the result in `column`:

      changeset
      |> cast(attrs, [:email])
      |> put_index(:email, :email_index)

  Three behaviours are decision 5's and decision 8's rather than conveniences,
  and each is observable:

    * **A source that was not changed is not recomputed.** The changeset is
      returned untouched - not with the same value written again - so a
      changeset that does not cast the source leaves a stored index alone
      instead of rewriting it, and so an update in a scope that cannot derive
      the key does not raise for a field it was not touching.
    * **A source set to `nil` sets the index to `nil`.** A `NULL` plaintext
      beside a non-`NULL` index would leak that a value exists, which is
      exactly ADR-0001 decision 7's rule. No key is derived on that path,
      because none is needed: writing `NULL` is not a computation and a
      missing tenant does not make it one.
    * **A source set to `""` gets a real index value**, over `norm("")`. That
      is a constant per key scope, so a host indexing a column where the empty
      string is common publishes that fact to anyone reading cardinality.

  Raises `Encryptor.Ecto.MissingTenantError` when a `scope: :tenant` index is
  computed outside tenant scope, `Encryptor.Ecto.BlindIndex.NormalizationError`
  when the declared normalizer cannot produce a binary, and `ArgumentError`
  when no index is declared for the `{source, column}` pair. There is no
  `:error` arm, for ADR-0001 decision 6's reason: the failure paths raise.

      iex> alias Encryptor.Ecto.TestSchemas.Customer
      iex> %Customer{email: "bob@example.com", email_index: <<0, 1, 2>>}
      ...> |> Ecto.Changeset.cast(%{email: nil}, [:email])
      ...> |> Encryptor.Ecto.BlindIndex.put_index(:email, :email_index)
      ...> |> Ecto.Changeset.fetch_change(:email_index)
      {:ok, nil}

      iex> alias Encryptor.Ecto.TestSchemas.Customer
      iex> %Customer{}
      ...> |> Ecto.Changeset.cast(%{}, [:email])
      ...> |> Encryptor.Ecto.BlindIndex.put_index(:email, :email_index)
      ...> |> Ecto.Changeset.fetch_change(:email_index)
      :error
  """
  @spec put_index(Changeset.t(), atom(), atom()) :: Changeset.t()
  def put_index(%Changeset{} = changeset, source, column)
      when is_atom(source) and is_atom(column) do
    declaration = Declaration.fetch!(changeset_schema!(changeset), source, column)

    case Changeset.fetch_change(changeset, source) do
      :error ->
        changeset

      {:ok, nil} ->
        Changeset.put_change(changeset, column, nil)

      {:ok, value} ->
        Changeset.put_change(changeset, column, Value.compute!(declaration, value, :dump))
    end
  end

  # -- the read side (decisions 5 and 9) ------------------------------------

  @doc """
  Adds an equality constraint on a full-width index.

      from(c in Customer) |> where_eq(:email, "bob@example.com")

  expands to `where: c.email_index == ^computed`, and to nothing else.
  Equality is the whole surface (decision 9): there is no `where_like`, no
  `where_gt`, no ordering helper, and no operator argument.

  The value is normalized before it is fingerprinted, so the query finds
  `"Bob@Example.COM "` when asked for `"bob@example.com"` under a
  `normalize: :email` index. Normalization is lossy and directional, and an
  index hit is not proof of byte equality.

  Raises `Encryptor.Ecto.MissingTenantError` when the index is `scope: :tenant`
  and there is no tenant in scope - **at build time**, which is the point:
  a query built outside scope must not be executable and match nothing.

  Raises `ArgumentError` when the index is truncated (`bits` other than `256`),
  naming `where_eq_candidates/3`, because a truncated index answers with a
  candidate set the caller has to filter after decrypting and a call site that
  did not say so has forgotten it.

      iex> import Encryptor.Ecto.BlindIndex
      iex> alias Encryptor.Ecto.TestSchemas.Customer
      iex> Encryptor.Ecto.Tenant.put("merchant_7f3")
      iex> where_eq(Customer, :phone, "+1 (555) 0100").wheres |> length()
      1
  """
  @spec where_eq(Ecto.Queryable.t(), atom(), term()) :: Ecto.Query.t()
  def where_eq(queryable, source, value) when is_atom(source) do
    query = Ecto.Queryable.to_query(queryable)
    declaration = sole_declaration!(query_schema!(query), source, "where_eq/3", "where_eq/4")

    where_eq(query, source, declaration.column, value)
  end

  @doc """
  The same, naming the index column.

  Decision 7's rotation window is what this exists for: while both versions
  are declared, the source field names two indexes and neither is the one
  meant. It is also the form to reach for beside decision 3d's per-tenant and
  `scope: :global` pair on one field.
  """
  @spec where_eq(Ecto.Queryable.t(), atom(), atom(), term()) :: Ecto.Query.t()
  def where_eq(queryable, source, column, value) when is_atom(source) and is_atom(column) do
    query = Ecto.Queryable.to_query(queryable)
    declaration = Declaration.fetch!(query_schema!(query), source, column)

    refuse_truncated!(declaration)
    equality(query, declaration, value)
  end

  @doc """
  Adds an equality constraint on a truncated index. Returns candidates: the
  caller filters after decrypting.

  A narrower index produces false-positive matches at a known rate, which is
  decision 6's whole purpose - the collisions blur the equality structure an
  attacker reads out of the column. The cost is that the rows this constrains
  are candidates rather than matches, and **the host must filter them after
  decrypting**. The name is the reminder; the record chose it so the call site
  could not forget.

  It also accepts a full-width index, where the candidate set happens to be
  exact. Refusing that direction as well would make the pairing total, and
  ADR-0003 states only the other half of it - `where_eq/3` refusing a truncated
  index - so the reverse refusal is left to the record rather than decided
  here. The weaker contract is sound over a full-width index either way.

  Raises exactly what `where_eq/3` raises, minus the truncation refusal.
  """
  @spec where_eq_candidates(Ecto.Queryable.t(), atom(), term()) :: Ecto.Query.t()
  def where_eq_candidates(queryable, source, value) when is_atom(source) do
    query = Ecto.Queryable.to_query(queryable)

    declaration =
      sole_declaration!(
        query_schema!(query),
        source,
        "where_eq_candidates/3",
        "where_eq_candidates/4"
      )

    where_eq_candidates(query, source, declaration.column, value)
  end

  @doc """
  The same, naming the index column.
  """
  @spec where_eq_candidates(Ecto.Queryable.t(), atom(), atom(), term()) :: Ecto.Query.t()
  def where_eq_candidates(queryable, source, column, value)
      when is_atom(source) and is_atom(column) do
    query = Ecto.Queryable.to_query(queryable)

    equality(query, Declaration.fetch!(query_schema!(query), source, column), value)
  end

  @doc """
  The index value itself, for hosts building their own queries.

  The read-side computation, asked of the tenant strategy with `:load` exactly
  as `where_eq/3` is, so a host-built query and a helper-built one constrain
  the same bytes.

  A host using this to *write* a column - a backfill, a second write path -
  is on the write side and should reach for `put_index/3`, which asks with
  `:dump`. The two differ only for a host whose resolver answers differently
  for reads and writes, and that host is the one ADR-0001 has in mind when it
  allows it.

  The returned value is a directly usable search token. It is on ADR-0003's
  never-logged list beside plaintext and key material, and a host that puts one
  in a log line has published the ability to confirm that value's presence to
  anyone reading it.

      iex> alias Encryptor.Ecto.BlindIndex
      iex> alias Encryptor.Ecto.TestSchemas.Customer
      iex> Encryptor.Ecto.Tenant.put("merchant_7f3")
      iex> byte_size(BlindIndex.compute(Customer, :phone, "+1 (555) 0100"))
      32
  """
  @spec compute(module(), atom(), term()) :: binary()
  def compute(schema, source, value) when is_atom(schema) and is_atom(source) do
    Value.compute!(sole_declaration!(schema, source, "compute/3", "compute/4"), value, :load)
  end

  @doc """
  The same, naming the index column.
  """
  @spec compute(module(), atom(), atom(), term()) :: binary()
  def compute(schema, source, column, value)
      when is_atom(schema) and is_atom(source) and is_atom(column) do
    Value.compute!(Declaration.fetch!(schema, source, column), value, :load)
  end

  # -- resolving what the helpers were pointed at ---------------------------

  @spec equality(Ecto.Query.t(), Declaration.t(), term()) :: Ecto.Query.t()
  defp equality(query, declaration, value) do
    computed = Value.compute!(declaration, value, :load)
    column = declaration.column

    Ecto.Query.where(query, [record], field(record, ^column) == ^computed)
  end

  @spec refuse_truncated!(Declaration.t()) :: :ok
  defp refuse_truncated!(%Declaration{bits: @full_width}), do: :ok

  defp refuse_truncated!(%Declaration{} = declaration) do
    raise ArgumentError,
          "#{at(declaration)} is declared bits: #{declaration.bits}, and where_eq/3 " <>
            "answers with matches rather than candidates. A truncated index collides " <>
            "on purpose (ADR-0003 decision 6), so the rows it constrains are candidates " <>
            "the caller filters after decrypting: call where_eq_candidates/3, whose " <>
            "name is where that obligation is written down."
  end

  # The three-argument helpers take the source field, which is what a host
  # thinks in and what the record's typespecs name. A field carrying decision
  # 3d's pair or decision 7's rotation pair has two, and picking one would pick
  # a key - so this refuses, and names the form that says which.
  @spec sole_declaration!(module(), atom(), String.t(), String.t()) :: Declaration.t()
  defp sole_declaration!(schema, source, named, disambiguating) do
    case Declaration.list(schema, source) do
      [declaration] ->
        declaration

      [] ->
        raise ArgumentError,
              "#{inspect(schema)} declares no blind index on #{inspect(source)}, so " <>
                "#{named} has nothing to compute. Declared on this schema: " <>
                "#{declared_summary(schema)}."

      declarations ->
        raise ArgumentError,
              "#{inspect(schema)} declares #{length(declarations)} blind indexes on " <>
                "#{inspect(source)}, stored in " <>
                "#{Enum.map_join(declarations, ", ", &inspect(&1.column))}, and they " <>
                "derive under different keys. #{named} cannot choose between them: " <>
                "name the index column with #{disambiguating}."
    end
  end

  @spec changeset_schema!(Changeset.t()) :: module()
  defp changeset_schema!(%Changeset{data: %{__struct__: schema}}), do: schema

  defp changeset_schema!(%Changeset{}) do
    raise ArgumentError,
          "put_index/3 needs a changeset over a schema struct: the index's " <>
            "normalization and key derivation are read from the schema's own " <>
            "declaration, and a changeset over a bare map has none to read."
  end

  # `from.source` is `{table, schema}` for a query over a schema and carries a
  # `nil` schema for `from(c in "customers")`. The helpers cannot work from a
  # table name: the declaration lives on the schema module, and so does the
  # encrypted field whose frozen context reaches the derivation.
  @spec query_schema!(Ecto.Query.t()) :: module()
  defp query_schema!(%Ecto.Query{from: %{source: {_table, schema}}})
       when is_atom(schema) and not is_nil(schema),
       do: schema

  defp query_schema!(%Ecto.Query{}) do
    raise ArgumentError,
          "a blind index helper needs a queryable over a schema module. The " <>
            "declaration and the encrypted field's frozen declared context both live " <>
            "on the schema, and a query over a table name or a subquery has neither."
  end

  @spec declared_summary(module()) :: String.t()
  defp declared_summary(schema) do
    case Declaration.list(schema) do
      [] -> "(none)"
      declarations -> Enum.map_join(declarations, ", ", &inspect(&1.source))
    end
  end

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
