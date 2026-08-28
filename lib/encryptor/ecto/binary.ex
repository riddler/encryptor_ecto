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
  | `:legacy` | no | The migration window's legacy type: load through it when the primary load fails (see "The migration window" below) |
  | `:table`, `:column` | no | Overrides for the frozen declared context values, writable at the `use` or at the field |

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

  Because the values are frozen at declaration, renaming the physical table or
  column costs nothing: pin the old strings with `:table` and `:column` and
  stored rows stay readable.

      schema "payment_cards" do
        field :pan, Payments.Encrypted.Binary, table: "cards", column: "pan"
      end

  A pin written at the field wins over one written at the `use`, which wins
  over the derivation. The field is where a pin usually belongs, because a
  type module is shared by every field that names it while a pin is about one
  column. Changing a *declared* value is the expensive direction - it
  invalidates every row in the column and is a re-encryption migration. And
  two fields must not share one declared pair, or each can decrypt the other's
  bytes;
  `Encryptor.Ecto.Declarations.check_unique!/1` is the start-time check that
  says so, and where a host calls it.

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

  ## The migration window: `:legacy`

  `legacy:` names the type module the host was reading this column with
  before - a `cloak_ecto` type, a hand-rolled one - so that a column holding
  both formats at once is readable for as long as the migration takes
  (ADR-0001 acceptance amendment 4, ADR-0004 decision 4).

      defmodule Payments.Encrypted.Binary do
        use Encryptor.Ecto.Binary,
          vault: Payments.Vault,
          legacy: Payments.Cloak.Encrypted.Binary
      end

  ### Order, and what triggers the fallback

  The primary load is attempted **first, always**. The legacy load is
  attempted **only** when the vault refuses the stored bytes - the failure
  that would otherwise raise `Encryptor.Ecto.DecryptError`. It is not
  attempted for `Encryptor.Ecto.MissingTenantError` or
  `Encryptor.Ecto.MissingContextError`: those are host misconfiguration, they
  are loud on purpose, and a fallback that answered them with a successful
  legacy read would convert a configuration bug into a silent year of
  un-migrated rows (decision 4a).

  The order is also what makes the window cheap. It costs one failed decrypt
  per legacy row and nothing at all per migrated row, and the population of
  legacy rows only shrinks.

  ### Which error survives

  If both loads fail, the exception raised is the **primary**
  `Encryptor.Ecto.DecryptError`. The legacy attempt's reason travels in that
  exception's non-contractual `:engine` field, redacted like everything else
  in it, and must never be matched for control flow (decision 4b). Raising the
  legacy error would report a self-expiring compatibility shim as the cause of
  what is usually a genuine integrity event.

  ### Nothing writes through legacy, ever

  `dump/3` has no legacy arm and never will (decision 4c). A value read
  through the legacy path and written back is written in the new format, which
  is what makes ordinary application traffic migrate rows on its own during
  the window.

  ### What the legacy module has to be

  A module exporting `load/1` and returning `{:ok, value} | :error` - the
  `Ecto.Type` shape, which is what every `cloak_ecto` type and every
  hand-rolled type already is. It is checked at the declaration rather than on
  the first legacy row, the way `Encryptor.Ecto.Map` checks its `:json`.

  A legacy scheme behind something else - an `Ecto.ParameterizedType`, a
  sidecar service - is reachable by writing a one-function module around it,
  and that is the supported route: this type constructs no params for a
  foreign type and has no plan to construct them from. The migrator's `from:`
  accepts more shapes than this option does, because ADR-0002 decision 3 has
  it construct both sides' params itself and this type does not.

  A zero-arity function returned by the legacy module is invoked once and its
  result is the value, because deferred decryption is a real convention among
  legacy types (`cloak_ecto`'s `closure: true`) and a field that held the
  function rather than the value would be a defect. This mirrors the rule
  ADR-0004 decision 2 states for the migrator's `Source` contract.

  Whatever the legacy module returns is the field's value as-is: this type
  does not re-check it, and for `Encryptor.Ecto.Map` that means the legacy
  module returns the map rather than bytes to deserialize.

  ### The window is a security downgrade, and it is meant to end

  While `legacy:` is set, a row that has not been rewritten yet is read under
  the legacy scheme's rules: for a `cloak_ecto` host, with no encryption
  context binding it to its row and no per-tenant key separation. No
  *migrated* row is weakened; the guarantee is per-row until the rewrite
  finishes (decision 5). Dropping `legacy:` is the last step of the runbook,
  not a thing to remember.

  Every load that falls through to the legacy path emits

      :telemetry.execute([:encryptor_ecto, :legacy_load], %{count: 1},
        %{table: "cards", column: "pan"})

  and the metadata set is closed at those two keys: no value, no bytes, no
  reason, no tenant. Widening it is a security review rather than a feature
  (decision 5). The pair is table and column precisely because the window is
  per-field: a host with twelve encrypted columns finishes eleven and still
  has one legacy reader open.

  **The counter is a convenience, not proof.** ADR-0004's Q4 names the reason
  and this documentation is the answer to it: a counter that has read zero for
  a retention period is evidence about *traffic*, not about *rows*, so a table
  with a cold partition nobody reads reports zero while still holding legacy
  bytes. `Encryptor.Ecto.Migrator.verify/2` over `sample: :all` is the primary
  signal, and it is what a host drops `legacy:` on. Only the failed decrypt
  that preceded a successful legacy read is counted - a load that failed
  through *both* paths raises, which is louder than a counter and is not a
  legacy row in the sense the window is about.
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
          column: String.t(),
          legacy: module() | nil
        }

  @typedoc """
  Which of the two readers answered a load.

  `:primary` is the vault; `:legacy` is the module named by `:legacy`, and the
  value it returned is that module's, unchecked by this one.
  """
  @type load_arm :: :primary | :legacy

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

      # The marker `Encryptor.Ecto.Declarations` recognises this type by. A
      # marker rather than the shape of the params, so that an unrelated
      # parameterized type carrying `:table` and `:column` keys is never
      # mistaken for an encrypted field.
      @doc false
      def __encryptor_ecto__(:impl), do: unquote(impl)

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
  def validate_declaration!(module, opts),
    do: validate_declaration!(module, opts, __MODULE__, [])

  @doc """
  The same check, on behalf of a type built over this one.

  `Encryptor.Ecto.String` and `Encryptor.Ecto.Map` share this option set rather
  than re-implementing it, so a closed set stays closed in one place.
  `declared_by` is the macro the host actually wrote, so the message names the
  module a reader has to go and look up; `extra_options` is what that type adds
  to the set (`:json`, for `Map`, and nothing for `String`).
  """
  @spec validate_declaration!(module(), keyword(), module(), [atom()]) :: keyword()
  def validate_declaration!(module, opts, declared_by, extra_options) do
    if not Keyword.keyword?(opts) do
      raise ArgumentError,
            "#{inspect(module)}: use #{inspect(declared_by)} expects a keyword list of options"
    end

    known = @known_options ++ extra_options

    case Keyword.keys(opts) -- known do
      [] -> :ok
      unknown -> raise ArgumentError, unknown_options_message(module, unknown, declared_by, known)
    end

    if not Keyword.has_key?(opts, :vault) do
      raise ArgumentError, missing_vault_message(module, declared_by)
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

  A `:legacy` module is resolved here too, and refused here if it cannot read
  bytes: a declaration that names a legacy type which turns out not to export
  `load/1` is a migration window the host believes it has and does not, and
  the first row is the wrong place to find that out.
  """
  @spec init(keyword(), keyword()) :: params()
  def init(declared, field_opts) do
    params = %{
      vault: Keyword.fetch!(declared, :vault),
      tenant: validated_tenant(declared),
      context: validated_context(declared),
      table: declared_value(declared, :table, field_opts, &derive_table/1),
      column: declared_value(declared, :column, field_opts, &derive_column/1)
    }

    Map.put(params, :legacy, validated_legacy!(declared, params))
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

  Where the declaration named `:legacy`, a vault refusal falls through to that
  module rather than raising - see the moduledoc for the order, the trigger,
  and which error survives when both fail.
  """
  @spec load(term(), function(), params()) :: {:ok, term()}
  def load(nil, _loader, _params), do: {:ok, nil}

  def load(value, _loader, params) when is_binary(value) do
    {_arm, loaded} = load_arm(value, params)
    {:ok, loaded}
  end

  def load(value, _loader, params), do: refuse_non_binary!(params, :load, value)

  @doc """
  The same load, saying which of the two readers answered it.

  Public because a type built over this one can have work to do on the value
  that only makes sense for one arm - `Encryptor.Ecto.Map` deserializes the
  vault's plaintext and must *not* deserialize what a legacy module already
  returned as a map. Every other caller wants `load/3`.

  Raises exactly what `load/3` raises, for exactly the same conditions.
  """
  @spec load_arm(binary(), params()) :: {load_arm(), term()}
  def load_arm(value, params) when is_binary(value) do
    tenant = resolve_tenant!(params, :load)

    case params.vault.decrypt(value, vault_opts(params, tenant)) do
      {:ok, plaintext} ->
        {:primary, plaintext}

      {:error, %Error{reason: {:missing_required_context_keys, keys}} = error} ->
        raise MissingContextError, common(params, tenant, error.reason) ++ [missing_keys: keys]

      {:error, %Error{} = error} ->
        legacy_arm_or_raise!(value, params, tenant, error)
    end
  end

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

  @doc """
  The encryption-context key *names* a declaration composes, sorted.

  Public because a type built over this one can fail on the plaintext side of
  the vault call - `Encryptor.Ecto.Map`'s serializer does - and has to fill in
  the same identifying fields on its own exception without recomposing the
  context, which is the one thing that must not drift between the two.

      iex> Encryptor.Ecto.Binary.context_keys(%{context: %{"purpose" => "pii"},
      ...>   table: "cards", column: "pan"})
      ["column", "purpose", "table"]
  """
  @spec context_keys(params()) :: [String.t()]
  def context_keys(params), do: params |> encryption_context() |> Map.keys() |> Enum.sort()

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
      context_keys: context_keys(params),
      tenant: tenant_for_report(tenant),
      reason: reason
    ]
  end

  defp tenant_for_report(:none), do: :none
  defp tenant_for_report(tenant), do: tenant

  # -- the migration window -------------------------------------------------

  # ADR-0004 decision 4a: the fallback hangs off the vault's refusal of the
  # stored bytes and nothing else. `MissingTenantError` never reaches here at
  # all (it is raised before the vault is called) and `MissingContextError`
  # has its own arm above, which is what keeps a host misconfiguration from
  # being answered by a successful legacy read.
  @spec legacy_arm_or_raise!(binary(), params(), String.t() | :none, Error.t()) ::
          {:legacy, term()}
  defp legacy_arm_or_raise!(_value, %{legacy: nil} = params, tenant, error) do
    raise DecryptError, common(params, tenant, error.reason) ++ [engine: error.engine]
  end

  defp legacy_arm_or_raise!(value, params, tenant, error) do
    case legacy_load(params.legacy, value) do
      {:ok, loaded} ->
        emit_legacy_load(params)
        {:legacy, loaded}

      # Decision 4b: the primary error is the one raised. The legacy reason
      # rides in `:engine`, which is not a contract and is redacted like every
      # other field - a compatibility shim reported as the cause of an
      # integrity event would send an operator to the wrong investigation.
      {:error, reason} ->
        raise DecryptError,
              common(params, tenant, error.reason) ++
                [engine: {:legacy_load_also_failed, error.engine, reason}]
    end
  end

  # The legacy module is the host's own working reader, so its contract is
  # `Ecto.Type`'s rather than this package's, and the `{:ok, v} | {:error, e}`
  # the rest of the package speaks is composed here. Nothing is swallowed: the
  # only caller raises on every `:error`, and it raises from outside this
  # rescue so a failing legacy module's stacktrace is not carried into the
  # exception a host sees.
  #
  # The rescued exception is reduced to its *module*. A legacy type's own
  # error struct is free to carry the ciphertext it choked on or the plaintext
  # it half-produced, and folding its message in would put either into a
  # failure report through the back door ADR-0001 decision 6 closes at the
  # front.
  @spec legacy_load(module(), binary()) :: {:ok, term()} | {:error, term()}
  defp legacy_load(module, value) do
    case module.load(value) do
      {:ok, loaded} -> {:ok, unwrap_deferred(loaded)}
      :error -> {:error, {:legacy_declined, module}}
      _off_contract -> {:error, {:legacy_off_contract, module}}
    end
  rescue
    exception -> {:error, {:legacy_raised, module, exception.__struct__}}
  end

  # Deferred decryption is a real convention among legacy types - cloak's
  # `closure: true` returns a zero-arity function from `load/1` rather than the
  # plaintext - and a field left holding the function rather than the value
  # would be a defect this layer introduced. ADR-0004 decision 2 states the
  # unwrap as a generic rule about a pre-migration reader; it is the same
  # reader here. The value is invoked once and never rendered.
  @spec unwrap_deferred(term()) :: term()
  defp unwrap_deferred(loaded) when is_function(loaded, 0), do: loaded.()
  defp unwrap_deferred(loaded), do: loaded

  # ADR-0004 decision 5, and its metadata set is closed at these two keys. No
  # value, no bytes, no reason, no tenant: widening this map is a security
  # review rather than a feature. Emitted only where a legacy read *answered*,
  # because the event exists to count rows still in the old format and a load
  # that failed both ways raises instead.
  @spec emit_legacy_load(params()) :: :ok
  defp emit_legacy_load(params) do
    :telemetry.execute(
      [:encryptor_ecto, :legacy_load],
      %{count: 1},
      %{table: params.table, column: params.column}
    )
  end

  # -- declaration-time derivation ------------------------------------------

  # A pin is read from the field first and from the `use` second, because a
  # type module is shared by every field that names it and a pin is about one
  # column. Pinning only at the `use` would mean a module per renamed column,
  # which is the rename tax acceptance amendment 5 exists to remove - and it
  # is the form `underivable_message/2` has always told hosts to write.
  @spec declared_value(keyword(), atom(), keyword(), (keyword() -> String.t() | nil)) ::
          String.t()
  defp declared_value(declared, key, field_opts, derive) do
    case pinned(field_opts, key) || pinned(declared, key) do
      nil -> derive.(field_opts) || raise ArgumentError, underivable_message(key, field_opts)
      value -> value
    end
  end

  @spec pinned(keyword(), atom()) :: String.t() | nil
  defp pinned(opts, key) do
    case Keyword.get(opts, key) do
      nil ->
        nil

      value when is_binary(value) and value != "" ->
        value

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

  # Checked at the declaration rather than at the first legacy row, the way
  # `Encryptor.Ecto.Map` checks its `:json`: a legacy module that cannot read
  # bytes is a compile-time mistake wherever it is discovered, and the row
  # that discovers it at runtime is one nobody can read.
  #
  # `Code.ensure_loaded?/1` before `function_exported?/2` for the reason given
  # at every other use of the pair in this package: the bare export check
  # answers false for a module that is merely not loaded yet, which under lazy
  # loading is the ordinary case for a legacy type nothing has called.
  @spec validated_legacy!(keyword(), map()) :: module() | nil
  defp validated_legacy!(declared, params) do
    case Keyword.get(declared, :legacy) do
      nil ->
        nil

      module when is_atom(module) ->
        cond do
          not Code.ensure_loaded?(module) ->
            raise ArgumentError, legacy_message(params, module, "could not be loaded")

          not function_exported?(module, :load, 1) ->
            raise ArgumentError, legacy_message(params, module, "does not export load/1")

          true ->
            module
        end

      other ->
        raise ArgumentError, legacy_message(params, other, "is not a module")
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

  defp unknown_options_message(module, unknown, declared_by, known) do
    """
    #{inspect(module)}: unknown option#{if length(unknown) == 1, do: "", else: "s"} \
    #{inspect(unknown)} for use #{inspect(declared_by)}.

    The option set is closed (ADR-0001 decision 3), because every option that \
    could weaken the encryption context is one nobody gets. It is: \
    #{inspect(known)}.
    """
  end

  defp missing_vault_message(module, declared_by) do
    """
    #{inspect(module)}: use #{inspect(declared_by)} requires a :vault.

        use #{inspect(declared_by)}, vault: Payments.Vault

    There is no application-environment fallback, by decision: a field whose \
    vault is configured somewhere else is a field whose key nobody can find by \
    reading the declaration.
    """
  end

  # Named by the declared table and column, the way every other message here
  # names a field: by the time this check runs they are frozen.
  defp legacy_message(params, module, complaint) do
    """
    #{params.table}.#{params.column}: the :legacy type #{inspect(module)} #{complaint}.

    It must be a module exporting load/1 and returning {:ok, value} or :error \
    - the Ecto.Type shape, which is what a cloak_ecto type and a hand-rolled \
    one already are (ADR-0004 decision 4). A legacy scheme behind anything \
    else is reached by writing a one-function module around it.

    The check runs at the declaration rather than at the first legacy row, \
    because a declaration that names a legacy type and gets no legacy load is \
    a migration window a host believes it has and does not.
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
