defmodule Encryptor.Ecto.BlindIndex.Derivation do
  @moduledoc """
  The blind index's key derivation: ADR-0003 decisions 2 and 3a, as amended on
  2026-08-27 and reworked onto the vault's salted derivation surface on
  2026-08-28.

  A blind index value is `HMAC-SHA256(index_key, norm(plaintext))`
  (ADR-0003 decision 1). This module is where `index_key` comes from, and
  nothing else: it computes no index values and reads no schema. It performs
  no cryptography of its own either - every byte comes back from
  `Encryptor.Vault.derive/3`, and this module's job is to name the scope that
  call derives under.

  ## The derivation

  ADR-0003 was accepted with index keys as derived subkeys under
  enc-ADR-0003 decision 7's `"encryptor/v1/blind-index"` label, while its own
  decision 2 states a literal domain-separation prefix. The operator's
  2026-08-27 ruling settled how the two compose - *"compose by nesting - the
  index key is derived as a subkey under the upstream label, and d2's literal
  prefix becomes the info string inside that subkey derivation"* - and the
  operator's 2026-08-28 ruling put the salt decision 2 always asked for
  underneath both:

  > I agree with the salt ruling - add the salt now via an upstream
  > HKDF-Extract amendment, shaped to A8's `{ikm_selector, salt, info,
  > length}`

  enc-ADR-0003 amendment A implements that shape, and the whole construction
  now lives in `Encryptor.Kdf.salted_subkey/5` behind
  `Encryptor.Vault.derive/3`:

      PRK         = HKDF-Extract(salt: vault's :derivation_salt, ikm: key material)
      purpose_key = HKDF-Expand(PRK, "encryptor/v1/blind-index", 32)
      index_key   = HKDF-Expand(purpose_key, info, 32)

  Three steps, each separating at its own layer. The salt is the vault's
  per-deployment `:derivation_salt` and is never this package's to supply -
  that is what makes two deployments provisioned from the same tenant key
  material derive unrelated index values, and it is why a restored backup or
  a cloned staging environment cannot be joined against production on an
  index column. The outer label separates the whole blind-index tree from
  every other use of a tenant's key material and belongs to `encryptor`; this
  package names the purpose `"blind-index"` and never spells the namespace by
  hand. The inner `info` separates this package's index derivation from
  anything else that might one day derive under that tree, and belongs to
  this record:

      info = "encryptor_ecto/blind_index/v1|" <> table <> "|" <> column <>
             "|" <> index_name <> "|" <> Integer.to_string(version)

  Both halves of the structural "an index key is never an encryption key"
  guarantee hold, and each component of `info` is load-bearing:

    * the **prefix** is the domain separation of decision 2, and it is
      structural rather than a matter of configuration discipline;
    * **table** and **column** are the encrypted field's *declared* context
      values - the ones ADR-0001 acceptance amendment 5 freezes at
      declaration, not the physical names in use today - so two columns
      holding the same plaintext produce unrelated index values and a dump
      cannot be joined across them;
    * **index_name** distinguishes two indexes over one column (decision 6: a
      full index and a truncated one, or a rotation pair);
    * **version** participates because the operator's D1 ruling says it does.
      Without it, decision 7's two-column rotation would recompute the new
      column to byte-identical values and rotate nothing while reporting that
      it had.

  ## Key material never arrives here

  This module never sees, receives, holds, or returns the key material an
  index key is derived from. That is ADR-0003's assumptions A8 and A11, and
  as of enc-ADR-0003 amendment A the vault discharges them: `derive/3`
  resolves the descriptor inside the vault's derivation path
  (`lib/encryptor/vault/derive.ex` in `encryptor`), derives there, and
  hands back derived bytes only. There is no argument on any function in this
  module that a tenant master key could be passed as, which is the strongest
  form the property can take - a rule that cannot be broken by a call site
  beats a rule a call site is asked to follow.

  The consequence, recorded rather than glossed: a component that can derive
  an index key is a component holding a vault that can also decrypt. Amendment
  A's consequences section says so plainly, and the independently wrapped
  index keys of ADR-0003's A9 resolution remain the upgrade path if a genuine
  search-only consumer materializes.

  ## The seam this module chose, and why

  `derive/3` calls `Encryptor.Vault.derive/3` itself rather than returning a
  scope for a caller to derive with. The salt sits at the *extract* step, over
  key material the vault refuses to export, so there is no arrangement in
  which this package composes the construction from parts: either the vault
  performs the whole derivation or the derivation is wrong. Everything except
  the one line that makes the call is pure - `info/1`, `derive_opts/2`,
  `outer_label/0`, and every validation - so the constants stay reviewable
  and testable without a vault, and only the composed result needs one.

  What is deliberately *not* here is where the vault module and the operation
  come from on a real write path. That is `put_index/3`'s, and it belongs to
  the surface bead rather than to this one.

  ## Scope

  `selector!/3` discharges decision 3a. It has no tenant channel of its own
  and does not read `Encryptor.Ecto.Tenant`: it asks the *encrypted field's*
  configured strategy through `Encryptor.Ecto.TenantContext`, so a host that
  replaced `:scope` with a resolver module gets the same replacement here for
  free, and a missing tenant raises `Encryptor.Ecto.MissingTenantError`
  identically to ADR-0001 decision 5c. A `scope: :global` index asks no
  resolver anything, which is decision 3c's whole point: the global choice is
  written at the field and visible to the reviewer.

  ## Redaction

  No message, log line, or `Inspect` output produced here carries plaintext,
  an index value, or key material. `Encryptor.Ecto.Error`'s prohibition
  applies unchanged; `Encryptor.Ecto.BlindIndex.DerivationError`'s reasons are
  tuples of atoms naming a violated constraint, never a value.
  """

  alias Encryptor.Ecto.BlindIndex.DerivationError
  alias Encryptor.Ecto.MissingTenantError
  alias Encryptor.Ecto.TenantContext
  alias Encryptor.Kdf
  alias Encryptor.Vault

  # enc-ADR-0003 decision 7's reserved purpose. `Encryptor.Kdf.label/1` writes
  # the "encryptor/v1/" namespace; naming the purpose here is what keeps the
  # reservation one-way.
  @outer_purpose "blind-index"

  # ADR-0003 decision 2's literal domain-separation prefix, and the separator
  # its `info` string joins components with. Both are verbatim from the
  # record; neither is composed from anything.
  @info_prefix "encryptor_ecto/blind_index/v1"
  @info_separator "|"

  # 32 bytes at both layers: the amendment's outer expansion says 32, and 32
  # is HMAC-SHA256's block-independent natural key size, which is what the
  # inner key is used as (decision 1).
  @key_bytes 32

  @enforce_keys [:table, :column, :index_name, :version]
  defstruct [:table, :column, :index_name, :version, scope: :tenant]

  @typedoc """
  One index's derivation identity: everything that reaches the HKDF `info`
  string, plus the key scope decision 3 chooses between.
  """
  @type t :: %__MODULE__{
          table: String.t(),
          column: String.t(),
          index_name: String.t(),
          version: pos_integer(),
          scope: scope()
        }

  @typedoc "ADR-0003 decision 3's key scope, declared at the field."
  @type scope :: :tenant | :global

  @typedoc """
  Which scope's key material a derivation needs.

  `{:tenant, tenant}` names the resolved tenant; `:global` names the
  deployment-wide index root of decision 3c.
  """
  @type selector :: {:tenant, String.t()} | :global

  @typedoc """
  The encrypted field's frozen parameters, as `Encryptor.Ecto.Binary` holds
  them. Only the four keys the tenant strategy needs are read.
  """
  @type field_params :: %{
          required(:vault) => module(),
          required(:tenant) => :scope | :none | module(),
          required(:table) => String.t(),
          required(:column) => String.t(),
          optional(atom()) => term()
        }

  @doc """
  Builds a validated derivation identity.

      iex> Encryptor.Ecto.BlindIndex.Derivation.new!(
      ...>   table: "payments",
      ...>   column: "card_number",
      ...>   index_name: "card_number_index"
      ...> )
      %Encryptor.Ecto.BlindIndex.Derivation{
        table: "payments",
        column: "card_number",
        index_name: "card_number_index",
        version: 1,
        scope: :tenant
      }

  `:version` defaults to `1`, matching `index_opts/0`'s default, so an index
  that declares no version derives under `...|<index_name>|1` and nothing
  about an existing declaration changes. `:scope` defaults to `:tenant`,
  matching decision 3a.

  Every component is a binary, never an atom. An atom would have to be
  rendered to reach the `info` string, and `Atom.to_string/1` renders a module
  alias as `"Elixir.Foo"` - a rendering that silently changes the derived key
  for a caller who thought they were passing a name. The conversion belongs at
  the declaration, where the atom is still visible.

      iex> Encryptor.Ecto.BlindIndex.Derivation.new!(
      ...>   table: "payments", column: "card_number", index_name: :card_number_index)
      ** (Encryptor.Ecto.BlindIndex.DerivationError) a blind index key could not be derived (table: "payments", column: "card_number", context keys: [], tenant: nil, reason: {:invalid, :index_name, :not_a_non_empty_binary}, index name: nil, index version: 1)

  A component may not carry the `info` string's own separator, for the reason
  `Encryptor.Kdf.label/1` refuses a purpose carrying `"/"`: a component that
  can spell a separator can spell a different identity's `info` string from a
  different starting point, and two indexes the design says are independent
  collapse onto one key.

      iex> Encryptor.Ecto.BlindIndex.Derivation.new!(
      ...>   table: "payments", column: "card_number", index_name: "a|b")
      ** (Encryptor.Ecto.BlindIndex.DerivationError) a blind index key could not be derived (table: "payments", column: "card_number", context keys: [], tenant: nil, reason: {:invalid, :index_name, :contains_separator}, index name: "a|b", index version: 1)
  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    struct = %__MODULE__{
      table: opts[:table],
      column: opts[:column],
      index_name: opts[:index_name],
      version: Keyword.get(opts, :version, 1),
      scope: Keyword.get(opts, :scope, :tenant)
    }

    Enum.each([:table, :column, :index_name], &validate_component!(struct, &1))
    validate_version!(struct)
    validate_scope!(struct)

    struct
  end

  @doc """
  The HKDF `info` string for one derivation identity.

  Public because it is the constant the operator's crypto read checks, and a
  value that can only be observed through the bytes it produces is a value
  nobody reviews.

      iex> Encryptor.Ecto.BlindIndex.Derivation.new!(
      ...>   table: "payments", column: "card_number", index_name: "card_number_index")
      ...> |> Encryptor.Ecto.BlindIndex.Derivation.info()
      "encryptor_ecto/blind_index/v1|payments|card_number|card_number_index|1"

  A version bump changes it, which is what makes decision 7's rotation rotate
  anything:

      iex> Encryptor.Ecto.BlindIndex.Derivation.new!(
      ...>   table: "payments", column: "card_number",
      ...>   index_name: "card_number_index", version: 2)
      ...> |> Encryptor.Ecto.BlindIndex.Derivation.info()
      "encryptor_ecto/blind_index/v1|payments|card_number|card_number_index|2"
  """
  @spec info(t()) :: String.t()
  def info(%__MODULE__{} = derivation) do
    Enum.join(
      [
        @info_prefix,
        derivation.table,
        derivation.column,
        derivation.index_name,
        Integer.to_string(derivation.version)
      ],
      @info_separator
    )
  end

  @doc """
  The label of the outer expansion, which belongs to `encryptor`.

      iex> Encryptor.Ecto.BlindIndex.Derivation.outer_label()
      "encryptor/v1/blind-index"
  """
  @spec outer_label() :: String.t()
  def outer_label, do: Kdf.label(@outer_purpose)

  @doc """
  The `Encryptor.Vault.derive/3` options one identity derives under.

  Public for the same reason `info/1` is: this is A8's scope, minus the one
  element that is never the caller's. The salt does not appear because the
  vault supplies it from its own `:derivation_salt` and refuses a caller's
  (enc-ADR-0003 amendment A decision 3) - an option list that could carry a
  salt is an option list a call site could get wrong.

      iex> alias Encryptor.Ecto.BlindIndex.Derivation
      iex> Derivation.new!(table: "payments", column: "card_number",
      ...>   index_name: "card_number_index")
      ...> |> Derivation.derive_opts({:tenant, "merchant_7f3"})
      [
        info: "encryptor_ecto/blind_index/v1|payments|card_number|card_number_index|1",
        length: 32,
        key: "merchant_7f3"
      ]

  A `scope: :global` index names no key, so a single-key vault's `:default`
  selector applies (decision 3c):

      iex> alias Encryptor.Ecto.BlindIndex.Derivation
      iex> Derivation.new!(table: "signups", column: "email",
      ...>   index_name: "email_index", scope: :global)
      ...> |> Derivation.derive_opts(:global)
      [info: "encryptor_ecto/blind_index/v1|signups|email|email_index|1", length: 32]
  """
  @spec derive_opts(t(), selector()) :: keyword()
  def derive_opts(%__MODULE__{} = derivation, selector) do
    [info: info(derivation), length: @key_bytes] ++ key_opt(derivation, selector)
  end

  @doc """
  Derives the 32-byte index key for one identity, through `vault`.

  The whole construction is the vault's - `Encryptor.Vault.derive/3` extracts
  under the deployment salt, expands under the reserved `"blind-index"`
  purpose, and expands again under this record's `info`. This function names
  the purpose and the scope and returns what comes back:

      selector = Derivation.selector!(derivation, params, :dump)
      {:ok, index_key} = Derivation.derive(Payments.Vault, derivation, selector)

  The result is the vault's tagged tuple, unwrapped by nothing here. A vault
  with no `:derivation_salt` configured answers
  `{:missing_config, [:derivation_salt]}`, a `%Encryptor.Key.Kms{}` descriptor
  answers `{:invalid_key_descriptor, :not_derivable}`, and both are the
  vault's to phrase because both are facts about the vault's configuration
  rather than about this index's declaration. Translating them into a
  `#{inspect(__MODULE__)}Error` would put this package's words on a
  misconfiguration it cannot see.
  """
  @spec derive(module(), t(), selector()) :: {:ok, binary()} | {:error, Encryptor.Error.t()}
  def derive(vault, %__MODULE__{} = derivation, selector) when is_atom(vault) do
    Vault.derive(vault, @outer_purpose, derive_opts(derivation, selector))
  end

  @doc """
  Resolves which scope's key material a derivation needs (decision 3a).

  A `scope: :global` index asks no resolver anything - the choice was made at
  the field, out loud, and decision 3c is what makes it visible:

      iex> alias Encryptor.Ecto.BlindIndex.Derivation
      iex> Derivation.new!(table: "identities", column: "email",
      ...>   index_name: "email_index", scope: :global)
      ...> |> Derivation.selector!(%{vault: Signups.Vault, tenant: :none,
      ...>      table: "identities", column: "email"}, :dump)
      :global

  A `scope: :tenant` index asks the encrypted field's own strategy, with the
  field's declared context as the resolver's params - the same call
  `Encryptor.Ecto.Binary` makes on the encryption path, so the two cannot
  disagree about which tenant a row belongs to.

  `operation` is the caller's, because ADR-0003 does not say which of
  `:dump`/`:load` an index computation is and a resolver may legitimately
  answer differently for a write and a read.
  """
  @spec selector!(t(), field_params(), TenantContext.operation()) :: selector()
  def selector!(%__MODULE__{scope: :global}, _params, _operation), do: :global

  def selector!(%__MODULE__{scope: :tenant} = derivation, params, operation) do
    case resolve(params, operation) do
      {:ok, tenant} when is_binary(tenant) ->
        {:tenant, tenant}

      :none ->
        raise MissingTenantError, missing_tenant(derivation, params, :field_declared_tenant_none)

      {:error, reason} ->
        raise MissingTenantError, missing_tenant(derivation, params, reason)

      _off_contract ->
        raise MissingTenantError,
              missing_tenant(
                derivation,
                params,
                {:resolver_off_contract, resolver(params.tenant)}
              )
    end
  end

  # A `tenant: :none` field has no tenant to key with, and decision 3c makes
  # the pairing a compile error at the declaration. Answering `:none` here
  # rather than asking a resolver keeps the runtime backstop honest: the
  # raise below says the field is global, which is the thing to fix.
  @spec resolve(field_params(), TenantContext.operation()) ::
          {:ok, String.t()} | :none | {:error, term()} | term()
  defp resolve(%{tenant: :none}, _operation), do: :none

  defp resolve(params, operation) do
    resolver = resolver(params.tenant)

    resolver.resolve(operation, %{
      vault: params.vault,
      table: params.table,
      column: params.column
    })
  end

  @spec resolver(:scope | module()) :: module()
  defp resolver(:scope), do: TenantContext.Scope
  defp resolver(module) when is_atom(module), do: module

  @spec missing_tenant(t(), field_params(), term()) :: keyword()
  defp missing_tenant(derivation, params, reason) do
    [
      table: params.table,
      column: params.column,
      context_keys: [],
      tenant: nil,
      reason: {:blind_index, derivation.index_name, reason}
    ]
  end

  # -- validation -----------------------------------------------------------

  @spec validate_component!(t(), atom()) :: :ok
  defp validate_component!(derivation, key) do
    case Map.fetch!(derivation, key) do
      value when is_binary(value) and value != "" ->
        if String.contains?(value, @info_separator) do
          refuse!(derivation, {:invalid, key, :contains_separator})
        end

        :ok

      _other ->
        refuse!(derivation, {:invalid, key, :not_a_non_empty_binary})
    end
  end

  @spec validate_version!(t()) :: :ok
  defp validate_version!(%__MODULE__{version: version} = derivation) do
    if is_integer(version) and version > 0 do
      :ok
    else
      refuse!(derivation, {:invalid, :version, :not_a_positive_integer})
    end
  end

  @spec validate_scope!(t()) :: :ok
  defp validate_scope!(%__MODULE__{scope: scope} = derivation) do
    if scope in [:tenant, :global] do
      :ok
    else
      refuse!(derivation, {:invalid, :scope, :not_tenant_or_global})
    end
  end

  # The selector half of A8's `ikm_selector`, mapped onto the vault's `:key`
  # option. A `:global` index names no key, so the vault's own `:default`
  # applies; a `:tenant` index names the tenant `selector!/3` resolved.
  #
  # A selector this clause does not recognise is refused here rather than
  # passed on, because the vault would answer `{:invalid_selector, term}`
  # naming a value this package constructed - and the value is a tenant
  # identifier, which is the one thing in this path a host may consider
  # sensitive.
  @spec key_opt(t(), term()) :: keyword()
  defp key_opt(_derivation, {:tenant, tenant}) when is_binary(tenant) and tenant != "",
    do: [key: tenant]

  defp key_opt(_derivation, :global), do: []

  defp key_opt(derivation, _selector),
    do: refuse!(derivation, {:invalid, :selector, :not_a_selector})

  # Only binaries reach the exception's identifying fields. A component that
  # failed validation may be any term the caller passed, and the family's
  # contract is that these fields hold names.
  @spec refuse!(t(), term()) :: no_return()
  defp refuse!(derivation, reason) do
    raise DerivationError,
      table: printable(derivation.table),
      column: printable(derivation.column),
      context_keys: [],
      tenant: nil,
      reason: reason,
      index_name: printable(derivation.index_name),
      version: derivation.version
  end

  @spec printable(term()) :: String.t() | nil
  defp printable(value) when is_binary(value), do: value
  defp printable(_value), do: nil
end
