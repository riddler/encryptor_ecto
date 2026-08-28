defmodule Encryptor.Ecto.Binary do
  @moduledoc """
  An encrypted `:binary` field, declared the way `cloak_ecto` declares one.

  A host writes one module per encrypted type and names it from the schema:

      defmodule Payments.Encrypted.Binary do
        use Encryptor.Ecto.Binary, vault: Payments.Vault
      end

      defmodule Payments.Cards.Card do
        use Ecto.Schema

        schema "cards" do
          field :merchant_id, :string
          field :pan, Payments.Encrypted.Binary
        end
      end

  The generated module implements `Ecto.ParameterizedType`, so changesets,
  queries and `Repo` calls keep their ordinary form and the encryption happens
  in the type rather than at the call site (ADR-0001 decision 1).

  ## The option set is closed

  | Option | Required | Meaning |
  |---|---|---|
  | `:vault` | yes | The `Encryptor.Vault` module this type encrypts through |
  | `:tenant` | no | `:scope` (default), `:none`, or a module implementing `Encryptor.Ecto.TenantContext` (see "A global field" below) |
  | `:context` | no | Static extra context pairs merged into every operation |
  | `:legacy` | no | The migration window's legacy type (not yet implemented - see below) |
  | `:table`, `:column` | no | Overrides for the frozen declared context values |

  An unknown option raises while the host module compiles, and there is no
  `Application` environment fallback for `:vault`: the vault is named at the
  declaration or the module does not compile (decision 3). Every option that
  could weaken the encryption context is one nobody gets, which is what makes
  the closed set worth its inconvenience.

  ## What goes in the encryption context

  `"table"` and `"column"`, derived once at declaration time from the schema's
  source and the field's name, plus whatever `:context` adds (decision 4). The
  tenant is **not** a context pair: it passes to the vault as `key:`, and the
  vault derives and injects `"tenant_ref"` itself (acceptance amendment 1). A
  declared `"table"` or `"column"` wins over a `:context` pair of the same
  name - the derived values are the anti-substitution property and a static
  pair cannot be allowed to shadow them.

  Schema prefixes are deliberately absent: a prefix is a deployment-time
  placement decision, and binding it would make a ciphertext un-restorable
  into a differently-prefixed database.

  ## `nil`, and empty

  `nil` dumps and loads as `nil`, with no encryption: a `NULL` column stays
  `NULL`, because presence is already visible to anyone holding the database
  and encrypting it would break every `is_nil` query a host has. An empty
  binary is *not* `nil` and *is* encrypted - `""` round-trips as `""`
  (decision 7).

  ## Failures raise; they never return `:error`

  `cast/2` keeps the ordinary `:error` arm, because a non-binary handed to
  this type genuinely is a validation failure, and `cast/2` never encrypts.
  `dump/3` and `load/3` have no `:error` arm at all (decision 6). An
  `Ecto.Type` `:error` surfaces as a validation-shaped `Ecto.ChangeError` that
  a changeset can catch and proceed past, writing the row without the value it
  was supposed to protect - which is the wrong shape for an infrastructure
  failure and a dangerous one for an integrity event.

  | Condition | Exception |
  |---|---|
  | No tenant resolved | `Encryptor.Ecto.MissingTenantError` |
  | The vault returned an encrypt error | `Encryptor.Ecto.EncryptError` |
  | The vault returned a decrypt error, AAD mismatch included | `Encryptor.Ecto.DecryptError` |
  | The vault reports missing required context keys | `Encryptor.Ecto.MissingContextError` |
  | A `tenant: :none` field names a `:tenant`-profile vault | `Encryptor.Ecto.VaultProfileError` |

  No exception message, and no `Inspect` of one, carries plaintext, ciphertext
  bytes or key material. That is structural rather than conventional: see
  `Encryptor.Ecto.Error`.

  ## A missing tenant is an error, deliberately

  With `tenant: :scope` - the default - the tenant comes from
  `Encryptor.Ecto.Tenant`, which the host sets at the edge of each unit of
  work. A dump with nothing in scope raises `Encryptor.Ecto.MissingTenantError`
  naming the table and the column (decision 5c). Not a default tenant, not a
  `nil` tenant, not a global key, not a log line: the failure that choice
  forbids is a row written under the wrong key because a background job
  forgot, which is durable and unrecoverable in a way an exception on the
  first test run is not.

  Loads raise the same way (decision 5d). Loading with whatever context the
  row implies and letting the AAD check fail would work, but a raise with a
  legible message beats an authentication failure that reads like data
  corruption. Where a tenant *is* in scope but is the wrong one, the AAD check
  is the backstop: the read fails authentication and arrives as
  `Encryptor.Ecto.DecryptError`, which is the anti-substitution property
  working rather than a missing-scope error.

  ## A global field: `tenant: :none`, and what it costs

  `tenant: :none` declares a field global. It is written at the field, in the
  schema, where a reviewer sees it next to the column it applies to, and it
  asks no resolver anything: nothing is read from `Encryptor.Ecto.Tenant`, and
  a dump with no tenant in scope is the ordinary case rather than an error.

  **A `:none` field's ciphertexts are not crypto-shreddable with a tenant
  key.** The tenant key is omitted from the vault call entirely, so those
  bytes belong to the vault's single key and nothing else. Destroying one
  tenant's key leaves every one of them readable, and removing that tenant's
  data from a `:none` column is an ordinary delete rather than a
  key-destruction. That is the trade the option is *for* - a lookup table, a
  pricing tier, a feature flag payload that no tenant owns - and it is stated
  here rather than left to the record, because the option is declared at the
  field and its consequence is a compliance one.

      defmodule Payments.Encrypted.Global do
        use Encryptor.Ecto.Binary, vault: Payments.AppVault, tenant: :none
      end

  ### A `:none` field must name a `:single`-profile vault

  A `:tenant`-profile vault carries the tenant reference in its required
  context set and refuses any operation without it, so "a tenant vault with
  the pair omitted" is not a configuration that exists. A host with both kinds
  of field runs two vaults: the per-tenant one its tenant-scoped fields point
  at, and a second single-key one its global fields point at.

  The rule is checked on the first `dump/3` or `load/3` of such a field, and
  violating it raises `Encryptor.Ecto.VaultProfileError` naming the field, the
  vault it named, and the profile that vault resolved to. It cannot be checked
  while the declaration compiles: `:context_profile` is ordinary vault
  configuration and arrives through layers - application environment,
  `start_link/1` options, `init/1` - that do not exist at the compile time of
  the vault module, let alone of a type module downstream of it. The
  authoritative copy is the frozen `Encryptor.Vault.Config` the vault
  publishes when it starts, and this type reads it from there rather than
  keeping a second one.

  ## Not queryable, and this package will not pretend otherwise

  No equality lookup, no `LIKE`, no ordering, no unique index, no `ON CONFLICT`
  target (decision 10). Ciphertext is non-deterministic, so `equal?/3` compares
  plaintext rather than stored bytes - otherwise every write would mark every
  encrypted field changed (decision 9).

  ## What this module does not do yet

  `:legacy` is part of the option set the record fixes, and its load arm is a
  separate bead. Rather than accept the option and silently do nothing with
  it - leaving a host believing it has a migration window it does not - a
  declaration that names `:legacy` raises at `init/1` saying so.
  """

  alias Encryptor.Ecto.DecryptError
  alias Encryptor.Ecto.EncryptError
  alias Encryptor.Ecto.MissingContextError
  alias Encryptor.Ecto.MissingTenantError
  alias Encryptor.Ecto.TenantContext
  alias Encryptor.Ecto.VaultProfileError
  alias Encryptor.Error
  alias Encryptor.Vault.Config

  @typedoc "The options `use Encryptor.Ecto.Binary` accepts."
  @type opts :: [
          vault: module(),
          tenant: :scope | :none | module(),
          context: %{optional(String.t()) => String.t()},
          legacy: module(),
          table: String.t(),
          column: String.t()
        ]

  @typedoc """
  What `init/2` freezes and every other callback receives.

  A map rather than a keyword list, as `Ecto.ParameterizedType` suggests, so
  the callbacks below pattern-match on it directly.
  """
  @type params :: %{
          vault: module(),
          tenant: :scope | :none | module(),
          context: %{optional(String.t()) => String.t()},
          table: String.t(),
          column: String.t()
        }

  @known_options [:vault, :tenant, :context, :legacy, :table, :column]

  @doc """
  Defines an encrypted `:binary` type on the using module.

  See the moduledoc for the option set; anything outside it raises here, while
  the host module is compiling.
  """
  @spec __using__(opts()) :: Macro.t()
  defmacro __using__(opts) do
    # The generated callbacks delegate to this module by an unquoted module
    # name rather than by writing it out, so nothing here injects an alias
    # into the host's module namespace on its way past.
    impl = __MODULE__

    quote do
      @behaviour Ecto.ParameterizedType

      @encryptor_ecto_declared unquote(impl).validate_declaration!(__MODULE__, unquote(opts))

      @doc false
      @impl Ecto.ParameterizedType
      def init(field_opts),
        do: unquote(impl).init(@encryptor_ecto_declared, field_opts)

      @doc false
      @impl Ecto.ParameterizedType
      def type(params), do: unquote(impl).type(params)

      @doc false
      @impl Ecto.ParameterizedType
      def cast(value, params), do: unquote(impl).cast(value, params)

      @doc false
      @impl Ecto.ParameterizedType
      def dump(value, dumper, params), do: unquote(impl).dump(value, dumper, params)

      @doc false
      @impl Ecto.ParameterizedType
      def load(value, loader, params), do: unquote(impl).load(value, loader, params)

      @doc false
      @impl Ecto.ParameterizedType
      def equal?(left, right, params), do: unquote(impl).equal?(left, right, params)

      @doc false
      @impl Ecto.ParameterizedType
      def embed_as(format, params), do: unquote(impl).embed_as(format, params)
    end
  end

  @doc """
  Checks a declaration's option set while the declaring module compiles.

  Returns the options unchanged when they are acceptable, so the macro above
  can assign the result straight into a module attribute.

      iex> Encryptor.Ecto.Binary.validate_declaration!(Payments.Encrypted.Binary,
      ...>   vault: Payments.Vault
      ...> )
      [vault: Payments.Vault]
  """
  @spec validate_declaration!(module(), keyword()) :: keyword()
  def validate_declaration!(module, opts) do
    if not Keyword.keyword?(opts) do
      raise ArgumentError,
            "#{inspect(module)}: use Encryptor.Ecto.Binary expects a keyword list of options"
    end

    case Keyword.keys(opts) -- @known_options do
      [] -> :ok
      unknown -> raise ArgumentError, unknown_options_message(module, unknown)
    end

    if not Keyword.has_key?(opts, :vault) do
      raise ArgumentError, missing_vault_message(module)
    end

    opts
  end

  @doc """
  Freezes a field's declared context, merging the declaration's options with
  the `:schema` and `:field` Ecto supplies.

  The derivation runs once, here, and its results are explicit values in the
  returned params rather than facts re-read from the live schema on every
  operation (acceptance amendment 5). Renaming the physical table or field
  while pinning `:table` or `:column` therefore leaves stored rows readable;
  changing a declared value invalidates the column and is a data migration.

  Raises when the table or the column cannot be resolved and was not supplied.
  A context-less encrypt is never performed (decision 4).
  """
  @spec init(keyword(), keyword()) :: params()
  def init(declared, field_opts) do
    if Keyword.has_key?(declared, :legacy) do
      raise ArgumentError, legacy_message(field_opts)
    end

    %{
      vault: Keyword.fetch!(declared, :vault),
      tenant: validated_tenant(declared),
      context: validated_context(declared),
      table: declared_value(declared, :table, field_opts, &derive_table/1),
      column: declared_value(declared, :column, field_opts, &derive_column/1)
    }
  end

  @doc """
  The column type, which is `:binary` whatever the plaintext was.

  Every one of these types stores the vault's bytes verbatim, so a migration
  has one column type to write and no length to guess (decisions 2 and 11).

      iex> Encryptor.Ecto.Binary.type(%{})
      :binary
  """
  @spec type(term()) :: :binary
  def type(_params), do: :binary

  @doc """
  Casts a value on its way into a changeset. Never encrypts.

  Keeps the ordinary `:error` arm, because a non-binary handed to a binary
  field really is a validation failure and belongs in a changeset's errors
  (decision 6).

      iex> Encryptor.Ecto.Binary.cast("4111111111111111", %{})
      {:ok, "4111111111111111"}

      iex> Encryptor.Ecto.Binary.cast(nil, %{})
      {:ok, nil}

      iex> Encryptor.Ecto.Binary.cast(:not_a_binary, %{})
      :error
  """
  @spec cast(term(), term()) :: {:ok, binary() | nil} | :error
  def cast(nil, _params), do: {:ok, nil}
  def cast(value, _params) when is_binary(value), do: {:ok, value}
  def cast(_value, _params), do: :error

  @doc """
  Encrypts a value on its way to the column.

  `nil` passes through unencrypted; everything else is handed to the vault
  under the resolved tenant, with the declared table and column as encryption
  context. There is no `:error` arm: the failure paths raise (decision 6).
  """
  @spec dump(term(), function(), params()) :: {:ok, binary() | nil}
  def dump(nil, _dumper, _params), do: {:ok, nil}

  def dump(value, _dumper, params) when is_binary(value) do
    tenant = resolve_tenant!(params, :dump)

    case params.vault.encrypt(value, vault_opts(params, tenant)) do
      {:ok, ciphertext} ->
        {:ok, ciphertext}

      {:error, %Error{reason: {:missing_required_context_keys, keys}} = error} ->
        raise MissingContextError, common(params, tenant, error.reason) ++ [missing_keys: keys]

      {:error, %Error{} = error} ->
        raise EncryptError, common(params, tenant, error.reason)
    end
  end

  def dump(value, _dumper, params), do: refuse_non_binary!(params, :dump, value)

  @doc """
  Decrypts the stored bytes on their way out of the column.

  `nil` passes through; everything else goes back to the vault unchanged, in
  the same context the write composed. There is no `:error` arm here either:
  a decrypt failure is an integrity event, not a validation error.
  """
  @spec load(term(), function(), params()) :: {:ok, binary() | nil}
  def load(nil, _loader, _params), do: {:ok, nil}

  def load(value, _loader, params) when is_binary(value) do
    tenant = resolve_tenant!(params, :load)

    case params.vault.decrypt(value, vault_opts(params, tenant)) do
      {:ok, plaintext} ->
        {:ok, plaintext}

      {:error, %Error{reason: {:missing_required_context_keys, keys}} = error} ->
        raise MissingContextError, common(params, tenant, error.reason) ++ [missing_keys: keys]

      {:error, %Error{} = error} ->
        raise DecryptError, common(params, tenant, error.reason) ++ [engine: error.engine]
    end
  end

  def load(value, _loader, params), do: refuse_non_binary!(params, :load, value)

  @doc """
  Compares plaintext, never stored bytes.

  The same plaintext encrypts to different bytes every time, so a comparison
  over dumped values would mark every encrypted field changed on every write
  (decision 9).

      iex> Encryptor.Ecto.Binary.equal?("4111111111111111", "4111111111111111", %{})
      true
  """
  @spec equal?(term(), term(), term()) :: boolean()
  def equal?(left, right, _params), do: left == right

  @doc """
  Embeds as the cast value rather than the dumped one (decision 9).

      iex> Encryptor.Ecto.Binary.embed_as(:json, %{})
      :self
  """
  @spec embed_as(atom(), term()) :: :self
  def embed_as(_format, _params), do: :self

  # -- tenant resolution ----------------------------------------------------

  # `tenant: :none` declares a field global and asks no resolver anything. The
  # rule that such a field must name a `:single`-profile vault is a check
  # against the vault's own start-time configuration rather than against this
  # package's options, which is why it runs here rather than in `init/2`.
  @spec resolve_tenant!(params(), TenantContext.operation()) :: String.t() | :none
  defp resolve_tenant!(%{tenant: :none} = params, _operation) do
    assert_single_profile_vault!(params)
    :none
  end

  defp resolve_tenant!(params, operation) do
    resolver = resolver(params.tenant)

    case resolver.resolve(operation, resolver_params(params)) do
      {:ok, tenant} when is_binary(tenant) ->
        tenant

      :none ->
        :none

      {:error, reason} ->
        raise MissingTenantError, common(params, nil, reason)

      _off_contract ->
        raise MissingTenantError, common(params, nil, {:resolver_off_contract, resolver})
    end
  end

  # ADR-0001 decision 5e as tightened by acceptance amendment 3: a `:none`
  # field must name a `:single`-profile vault. The profile is a start-time
  # value - it arrives through configuration layers that do not exist when
  # this module or the vault module is compiled - so the authoritative copy is
  # the frozen struct the vault published at start, and the check is a
  # `:persistent_term` read per call rather than anything memoized here.
  #
  # A vault that has not started has no frozen config and therefore no profile
  # to check. That is deliberately not this exception's business: the very
  # next line hands the value to the vault, whose own entry-point check
  # reports `{:vault_not_started, _}` through `EncryptError`/`DecryptError`.
  # Reporting a not-started vault as a profile defect would name the wrong
  # thing to fix.
  @spec assert_single_profile_vault!(params()) :: :ok
  defp assert_single_profile_vault!(params) do
    case Config.fetch(params.vault) do
      {:ok, %{context_profile: :tenant = profile}} ->
        raise VaultProfileError,
              common(params, :none, {:tenant_profile_vault, params.vault}) ++
                [vault: params.vault, profile: profile]

      {:ok, _single_profile} ->
        :ok

      {:error, %Error{}} ->
        :ok
    end
  end

  @spec resolver(:scope | module()) :: module()
  defp resolver(:scope), do: TenantContext.Scope
  defp resolver(module) when is_atom(module), do: module

  @spec resolver_params(params()) :: TenantContext.params()
  defp resolver_params(params) do
    %{vault: params.vault, table: params.table, column: params.column}
  end

  # -- the vault call -------------------------------------------------------

  # The tenant passes as `key:` and never as a context pair: the vault derives
  # `tenant_ref` from the selector itself, so the routing argument and the
  # context pair are incapable of disagreeing (acceptance amendment 1). A
  # `:none` field omits `:key` entirely, which is what a `:single`-profile
  # vault expects.
  @spec vault_opts(params(), String.t() | :none) :: keyword()
  defp vault_opts(params, :none), do: [encryption_context: encryption_context(params)]

  defp vault_opts(params, tenant),
    do: [key: tenant, encryption_context: encryption_context(params)]

  @spec encryption_context(params()) :: %{optional(String.t()) => String.t()}
  defp encryption_context(params) do
    Map.merge(params.context, %{"table" => params.table, "column" => params.column})
  end

  # The fields every exception in the family carries. `context_keys` are key
  # names; the values never leave this module, and neither does the plaintext.
  @spec common(params(), term(), term()) :: keyword()
  defp common(params, tenant, reason) do
    [
      table: params.table,
      column: params.column,
      context_keys: params |> encryption_context() |> Map.keys() |> Enum.sort(),
      tenant: tenant_for_report(tenant),
      reason: reason
    ]
  end

  defp tenant_for_report(:none), do: :none
  defp tenant_for_report(tenant), do: tenant

  # -- declaration-time derivation ------------------------------------------

  @spec declared_value(keyword(), atom(), keyword(), (keyword() -> String.t() | nil)) ::
          String.t()
  defp declared_value(declared, key, field_opts, derive) do
    case Keyword.get(declared, key) do
      value when is_binary(value) and value != "" ->
        value

      nil ->
        derive.(field_opts) || raise ArgumentError, underivable_message(key, field_opts)

      other ->
        raise ArgumentError,
              "expected #{inspect(key)} to be a non-empty string, got: #{inspect(other)}"
    end
  end

  # `:schema` arrives as the schema module, and at the moment a field is
  # declared that module is still being compiled - `__schema__/1` does not
  # exist yet. The source is readable from the attribute Ecto itself reads at
  # the same point. A schemaless use passes the source as a string, and a
  # module that has finished compiling answers for itself.
  @spec derive_table(keyword()) :: String.t() | nil
  defp derive_table(field_opts) do
    case Keyword.get(field_opts, :schema) do
      source when is_binary(source) and source != "" ->
        source

      module when is_atom(module) and not is_nil(module) ->
        source_of(module)

      _absent ->
        nil
    end
  end

  # `Code.ensure_loaded?/1` before `function_exported?/2` is not defensive
  # noise: `function_exported?/2` answers false for a module that is merely
  # not loaded yet, and under lazy loading that is the ordinary case for a
  # schema this process has not touched. Without it the derivation fails for a
  # reason that depends on load order, which is a defect that shows up as an
  # intermittently red suite and a host that cannot reproduce it.
  @spec source_of(module()) :: String.t() | nil
  defp source_of(module) do
    cond do
      Module.open?(module) ->
        Module.get_attribute(module, :ecto_source)

      Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) ->
        module.__schema__(:source)

      true ->
        nil
    end
  end

  @spec derive_column(keyword()) :: String.t() | nil
  defp derive_column(field_opts) do
    case Keyword.get(field_opts, :field) do
      field when is_atom(field) and not is_nil(field) -> Atom.to_string(field)
      _absent -> nil
    end
  end

  # -- validation and messages ----------------------------------------------

  @spec validated_tenant(keyword()) :: :scope | :none | module()
  defp validated_tenant(declared) do
    case Keyword.get(declared, :tenant, :scope) do
      strategy when strategy in [:scope, :none] ->
        strategy

      module when is_atom(module) and not is_nil(module) ->
        module

      other ->
        raise ArgumentError,
              "expected :tenant to be :scope, :none, or a module implementing " <>
                "Encryptor.Ecto.TenantContext, got: #{inspect(other)}"
    end
  end

  @spec validated_context(keyword()) :: %{optional(String.t()) => String.t()}
  defp validated_context(declared) do
    context = Keyword.get(declared, :context, %{})

    valid? =
      is_map(context) and
        Enum.all?(context, fn {key, value} -> is_binary(key) and is_binary(value) end)

    if not valid? do
      raise ArgumentError,
            "expected :context to be a map of string keys to string values, " <>
              "got: #{inspect(context)}"
    end

    context
  end

  defp unknown_options_message(module, unknown) do
    """
    #{inspect(module)}: unknown option#{if length(unknown) == 1, do: "", else: "s"} \
    #{inspect(unknown)} for use Encryptor.Ecto.Binary.

    The option set is closed (ADR-0001 decision 3), because every option that \
    could weaken the encryption context is one nobody gets. It is: \
    #{inspect(@known_options)}.
    """
  end

  defp missing_vault_message(module) do
    """
    #{inspect(module)}: use Encryptor.Ecto.Binary requires a :vault.

        use Encryptor.Ecto.Binary, vault: Payments.Vault

    There is no application-environment fallback, by decision: a field whose \
    vault is configured somewhere else is a field whose key nobody can find by \
    reading the declaration.
    """
  end

  defp legacy_message(field_opts) do
    """
    #{describe_field(field_opts)}: the :legacy option is part of the option \
    set but its load arm is not implemented yet (ece-e8k).

    It is refused rather than accepted-and-ignored: a declaration that names \
    a legacy type and gets no legacy load is a migration window a host \
    believes it has and does not.
    """
  end

  defp underivable_message(key, field_opts) do
    """
    #{describe_field(field_opts)}: could not derive the declared #{key} for an \
    encrypted field, and none was supplied.

    The table comes from the schema's source and the column from the field's \
    name. Outside a schema - a bare Ecto.Query cast, a schemaless changeset - \
    neither is available and both must be given:

        Ecto.ParameterizedType.init(Payments.Encrypted.Binary, \
    table: "cards", column: "pan")

    A context-less encrypt is never performed (ADR-0001 decision 4).
    """
  end

  # The value is never rendered, only its shape. An Ecto.Type failure arm is
  # the easiest place in this package to leak a plaintext, and the least
  # excusable.
  @spec refuse_non_binary!(params(), :dump | :load, term()) :: no_return()
  defp refuse_non_binary!(params, operation, value) do
    raise ArgumentError,
          "#{params.table}.#{params.column}: #{operation}/3 expects a binary or nil, " <>
            "and was given #{shape_of(value)}. Its value is deliberately not reported. " <>
            "A value that reached #{operation}/3 without passing cast/2 is wrong in the " <>
            "source rather than at runtime."
  end

  defp shape_of(value) when is_atom(value), do: "an atom"
  defp shape_of(value) when is_integer(value), do: "an integer"
  defp shape_of(value) when is_float(value), do: "a float"
  defp shape_of(value) when is_list(value), do: "a list"
  defp shape_of(value) when is_map(value), do: "a map"
  defp shape_of(value) when is_tuple(value), do: "a tuple"
  defp shape_of(_value), do: "a term of another type"

  defp describe_field(field_opts) do
    schema = Keyword.get(field_opts, :schema)
    field = Keyword.get(field_opts, :field)

    case {schema, field} do
      {nil, nil} -> "an encrypted field"
      {nil, field} -> inspect(field)
      {schema, nil} -> inspect(schema)
      {schema, field} -> "#{inspect(schema)}.#{field}"
    end
  end
end
