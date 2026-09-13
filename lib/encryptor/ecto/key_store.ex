defmodule Encryptor.Ecto.KeyStore do
  @moduledoc """
  The store-backed key provider: a wrapped-key table in, key descriptors out.

  `encryptor`'s ADR-0002 decision 5 puts the Ecto-backed provider in *this*
  package because it owns a schema, a migration and a repo, and its ADR-0003
  decision 9 says the vault package defines no storage at all: the vault owns
  the six fields of `Encryptor.Envelope.WrappedKey` and nothing about where
  they live. This module is the other half - the table, the query, and the
  `Encryptor.Provider` implementation that turns rows into the descriptors a
  tenant vault builds keyrings from.

  ## Configuring it

      defmodule MyApp.TenantVault do
        use Encryptor.Vault, otp_app: :my_app, context_profile: :tenant

        def init(config) do
          {:ok,
           Keyword.merge(config,
             provider:
               {Encryptor.Ecto.KeyStore,
                repo: MyApp.Repo,
                root_vault: MyApp.RootVault,
                reference_subkey: Encryptor.Envelope.root_subkey(root(), "tenant-ref")},
             reference_subkey: Encryptor.Envelope.root_subkey(root(), "tenant-ref")
           )}
        end
      end

  | Option | | |
  |---|---|---|
  | `:repo` | required | The `Ecto.Repo` the wrapped-key table lives in |
  | `:root_vault` | required | The vault the wrappings were produced by. `Static` provider, `cache: false` |
  | `:reference_subkey` | required | 32 bytes: the pinned reference root expanded under `"tenant-ref"` |
  | `:table` | `"encryptor_wrapped_keys"` | The table to read |

  ### `:reference_subkey` is required, and it is not an extra

  A row is found by `tenant_ref`, never by the selector: the selector is the
  host's tenant identifier and putting it in a column would publish it beside
  every ciphertext, which is the whole reason `Encryptor.Envelope.tenant_ref/2`
  is a keyed derivation rather than a hash. So resolving a selector to a row
  *is* that derivation, and the subkey it derives under has to be in provider
  state. It must be the same value the vault itself is configured with, or the
  provider will look for a row under one reference while the vault writes a
  header claiming another.

  ## What it does, and the three things it will not do

  `c:Encryptor.Provider.decryption_keys/2` reads every row for the selector's
  `tenant_ref`, newest version first, and unwraps each under the root vault.
  `c:Encryptor.Provider.encryption_key/2` is the head of that list, which is
  the provider contract's "the encryption key is the current one" stated as
  one query rather than two.

  It **mints nothing**. `c:Encryptor.Provider.init/1` resolves configuration
  and touches no database; neither callback writes. Key creation is
  `Encryptor.Envelope.provision/3`, re-wrap is `Encryptor.Envelope.rewrap/2`,
  and crypto-shred is a `DELETE` the host schedules - all of them verbs that
  operate on a key, which ADR-0002 decision 9 keeps out of this package's task
  list. Resolution is a lookup, and the provider contract requires exactly
  that: a provider that minted material on the first encrypt after a deploy
  would fail `Encryptor.Provider.Conformance`'s stability property, and
  rightly.

  It **issues no DDL**. The table arrives as generated migration source the
  host reads, commits and runs - `mix encryptor.ecto.gen.key_store_migration`,
  the same arrangement ADR-0002 decision 9 already makes for the migrator's
  checkpoint table.

  It **adds no cache**. The tenant vault's materials cache already collapses
  provider round trips to one per partition per `max_age`, and the provider
  contract names a second unbounded cache as the thing not to add.

  ## The table

  | Column | |
  |---|---|
  | `tenant_ref` | `Encryptor.Envelope.tenant_ref/2` of the host's selector. The lookup key |
  | `version` | the key version. Ordering is the store's job, per ADR-0002 decision 4 |
  | `namespace`, `name` | what the encrypted data key matches on, byte for byte |
  | `bits` | `256` on this path |
  | `wrapped` | the wrapping, whose kind the next column names |
  | `wrapping_shape` | which kind of wrapping `wrapped` holds: `"engine_message"` or `"gcp_kms_ciphertext"` |
  | `key_id` | `NULL` for an engine message; the `CryptoKey` id a GCP ciphertext was produced under |

  The last two are ADR-0005's, and they are the reason a reader never guesses.
  Both wrapping kinds are opaque binaries, so a reader that picks the wrong
  unwrap path gets a failure indistinguishable from a wrong key - one `varchar`
  per row removes the guess. The vocabulary is closed at those two values here,
  by that record, rather than by a database enum: this module queries the table
  schemalessly and names no adapter, so a third value is an amendment to the
  record and a clause in this module, not a migration on every adopter.

  Two unique indexes carry properties nothing at runtime can:

    * `{tenant_ref, version}` closes the race ADR-0003 leaves to this package -
      "calling `provision/3` twice concurrently for one tenant can produce two
      rows claiming the same version; the transaction that closes that race is
      `encryptor_ecto`'s". A second row claiming a live version is a candidate
      list with two entries for one version, and the loser of the race is the
      one no message was ever written under.
    * `{namespace, name}` is the name contract made mechanical. A name is bound
      to its bytes forever, and two rows sharing one is the failure the
      contract exists to prevent - caught by the database rather than years
      later as an undecryptable row.

  A shred is a `DELETE` of the row, which is honest: the wrapping is the only
  copy of the key, so destroying it destroys the key. Nothing here soft-deletes,
  because a soft-deleted wrapping is still a wrapping.

  ## The failure vocabulary

  Both callbacks answer in `t:Encryptor.Provider.reason/0` and nothing else.

    * `{:unknown_key, selector}` - no row for this selector's `tenant_ref`. A
      settled negative answer, and the same answer for a selector a tenant
      store cannot have a reference for at all (`:default`, `""`).
    * `{:key_unavailable, selector}` - the store could not be asked. The repo
      is not started, the connection pool is exhausted, the database is down.
      This is the one a caller retries, and telling it apart from the row
      genuinely being absent is why the provider contract carves both out of
      the decrypt path's collapse to `:decrypt_failed`.
    * `{:invalid_key_descriptor, :unwrap_failed}` - a row was found and did not
      unwrap under the root vault. During a root rotation that is the expected
      answer for a wrapping the rewrap pass has not reached yet. The
      underlying `Encryptor.Error` is deliberately not carried out of here: a
      provider's return travels into the vault's error struct, and a wrapped
      key's failure detail is the last place a value should be allowed to ride
      along.
    * `{:invalid_key_descriptor, {:unknown_wrapping_shape, value}}` - the row's
      `wrapping_shape` is not one of the two ADR-0005 decision 1 publishes.
      This one *does* carry the stored value out, and it is the only thing here
      that does: a shape is not a failure detail but one of a closed set of
      literals a record publishes, and an operator debugging a stray row needs
      to know which literal it was.
    * `{:invalid_key_descriptor, :missing_key_id}` - a `"gcp_kms_ciphertext"`
      row whose `key_id` is `NULL`. The requirement is a read-side rule rather
      than a `NOT NULL` because it is conditional on another column's value,
      and a conditional constraint is not portable DDL.
    * `{:invalid_key_descriptor, :unexpected_key_id}` - an `"engine_message"`
      row carrying a `key_id`. An engine message names its own keyring material
      inside the message, so a key id beside one means the row was written by
      something that did not know which shape it was writing.
    * `{:invalid_key_descriptor, {:unsupported_wrapping_shape,
      "gcp_kms_ciphertext"}}` - a well-formed GCP row this store cannot serve.
      ADR-0005's decision 5 branches per row, and its open question 2 leaves
      *where the GCP branch's client comes from* open; until that is decided
      this state holds a `root_vault` and nothing else, so the branch answers
      rather than crashes. A store with no GCP-shaped rows never reaches it.

  None of those four widens `t:Encryptor.Provider.reason/0`: they are new terms
  inside `{:invalid_key_descriptor, term()}`, which is open by construction.

  Records: `encryptor` ADR-0002 decisions 4, 5 and 6; ADR-0003 decisions 1, 3,
  4 and 9; this package's ADR-0002 decision 9 and ADR-0005.
  """

  @behaviour Encryptor.Provider

  import Ecto.Query, only: [from: 2]

  alias Encryptor.Envelope
  alias Encryptor.Envelope.WrappedKey
  alias Encryptor.Key.Aes
  alias Encryptor.Provider

  @default_table "encryptor_wrapped_keys"
  @reference_subkey_bytes 32
  @table_name ~r/^[a-z_][a-z0-9_]*$/

  @typedoc """
  What `c:Encryptor.Provider.init/1` freezes for the life of the vault.

  Everything in it is constant and none of it is a connection: the repo is a
  module name, and the pool behind it is the repo's own business.
  """
  @type state :: %{
          repo: module(),
          root_vault: module(),
          reference_subkey: binary(),
          table: String.t()
        }

  @typedoc "One row of the wrapped-key table, as selected by `rows/3`."
  @type row :: %{
          tenant_ref: String.t(),
          version: pos_integer(),
          namespace: String.t(),
          name: String.t(),
          bits: 256,
          wrapped: binary(),
          wrapping_shape: String.t(),
          key_id: String.t() | nil
        }

  @typedoc """
  The closed vocabulary of ADR-0005 decision 1, as the read side branches on it.

  The stored column is a string; this is what the string is translated into
  before anything dispatches on it, and the translation is where a value the
  record does not publish stops being a row.
  """
  @type wrapping_shape :: :engine_message | :gcp_kms_ciphertext

  @doc """
  The table name a host gets unless it names another.

      iex> Encryptor.Ecto.KeyStore.default_table()
      "encryptor_wrapped_keys"
  """
  @spec default_table() :: String.t()
  def default_table, do: @default_table

  @doc """
  Resolves the provider's options into state. Opens no connection.

  A missing or malformed option is refused here, at vault start, in the same
  terms `Encryptor.Vault.Config` uses for the same values - which is the point
  of refusing at start rather than on the first encrypted write.
  """
  @impl Provider
  @spec init(keyword()) :: {:ok, state()} | {:error, term()}
  def init(opts) when is_list(opts) do
    with {:ok, repo} <- module_option(opts, :repo),
         {:ok, root_vault} <- module_option(opts, :root_vault),
         {:ok, subkey} <- reference_subkey(opts),
         {:ok, table} <- table(opts) do
      {:ok, %{repo: repo, root_vault: root_vault, reference_subkey: subkey, table: table}}
    end
  end

  @doc """
  The newest live version for this selector.

  The head of `c:Encryptor.Provider.decryption_keys/2`, from the same single query, so the two
  cannot disagree about which version is current.
  """
  @impl Provider
  @spec encryption_key(state(), Provider.selector()) ::
          {:ok, Aes.t()} | {:error, Provider.reason()}
  def encryption_key(state, selector) do
    with {:ok, [head | _rest]} <- descriptors(state, selector), do: {:ok, head}
  end

  @doc """
  Every live version for this selector, newest first.

  Dropping a row from the table is what removes an entry from this list, and
  that is the crypto-shred mechanism rather than a cleanup.
  """
  @impl Provider
  @spec decryption_keys(state(), Provider.selector()) ::
          {:ok, [Aes.t(), ...]} | {:error, Provider.reason()}
  def decryption_keys(state, selector), do: descriptors(state, selector)

  @spec descriptors(state(), Provider.selector()) ::
          {:ok, [Aes.t(), ...]} | {:error, Provider.reason()}
  defp descriptors(state, selector) do
    with {:ok, ref} <- tenant_ref(state, selector),
         {:ok, rows} <- rows(state, ref, selector) do
      unwrap_all(state, rows, selector)
    end
  end

  # A selector a tenant reference cannot be derived from - `:default`, an empty
  # string - is not a store failure and not a caller retrying into success. It
  # is a selector this provider does not serve, which is what `:unknown_key`
  # means, and it is the arm `Encryptor.Provider.Conformance` holds every
  # adapter to.
  @spec tenant_ref(state(), Provider.selector()) ::
          {:ok, String.t()} | {:error, Provider.reason()}
  defp tenant_ref(state, selector) do
    case Envelope.tenant_ref(state.reference_subkey, selector) do
      {:ok, ref} -> {:ok, ref}
      {:error, _error} -> {:error, {:unknown_key, selector}}
    end
  end

  # The whole candidate list in one query, ordered by the store because
  # ordering information is the store's and not the struct's.
  #
  # The rescue is not a rescue-to-default: it is the translation an exception
  # needs to become the event the provider contract requires. `repo.all/1`
  # raises when the repo is not started and when the pool cannot answer, and
  # both of those are `:key_unavailable` - the reason a caller retries. The
  # exception itself is dropped rather than carried, for the reason the
  # moduledoc gives.
  @spec rows(state(), String.t(), Provider.selector()) ::
          {:ok, [map()]} | {:error, Provider.reason()}
  defp rows(state, ref, selector) do
    query =
      from(k in state.table,
        where: k.tenant_ref == ^ref,
        order_by: [desc: k.version],
        select: %{
          tenant_ref: k.tenant_ref,
          version: k.version,
          namespace: k.namespace,
          name: k.name,
          bits: k.bits,
          wrapped: k.wrapped,
          wrapping_shape: k.wrapping_shape,
          key_id: k.key_id
        }
      )

    {:ok, state.repo.all(query)}
  rescue
    _exception -> {:error, {:key_unavailable, selector}}
  end

  @spec unwrap_all(state(), [row()], Provider.selector()) ::
          {:ok, [Aes.t(), ...]} | {:error, Provider.reason()}
  defp unwrap_all(_state, [], selector), do: {:error, {:unknown_key, selector}}

  defp unwrap_all(state, rows, _selector) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case descriptor(state, row) do
        {:ok, descriptor} -> {:cont, {:ok, [descriptor | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, descriptors} -> {:ok, Enum.reverse(descriptors)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ADR-0005 decision 5: the dispatch is per row and at read time, never per
  # store. A host moving one tenant's wrapping from a root vault to GCP KMS has
  # a table holding both shapes at once for the length of that migration, and a
  # per-store setting would make the mixed window unrepresentable.
  @spec descriptor(state(), row()) :: {:ok, Aes.t()} | {:error, Provider.reason()}
  defp descriptor(state, row) do
    with {:ok, shape} <- shape(row.wrapping_shape), do: unwrap_row(state, shape, row)
  end

  # One clause per value the record publishes, plus a catch-all, and
  # deliberately not `String.to_existing_atom/1`: a stored shape is host data,
  # and turning host data into an atom-table lookup would make an unknown value
  # an `ArgumentError` raised from inside a provider callback rather than a
  # reason the contract already has a word for.
  @spec shape(String.t() | nil) :: {:ok, wrapping_shape()} | {:error, Provider.reason()}
  defp shape("engine_message"), do: {:ok, :engine_message}
  defp shape("gcp_kms_ciphertext"), do: {:ok, :gcp_kms_ciphertext}

  defp shape(other), do: {:error, {:invalid_key_descriptor, {:unknown_wrapping_shape, other}}}

  # The `key_id` rules are read-side because each is conditional on the shape,
  # and a conditional constraint is not portable DDL. A key id is a resource
  # name, so neither arm carries one out.
  @spec unwrap_row(state(), wrapping_shape(), row()) ::
          {:ok, Aes.t()} | {:error, Provider.reason()}
  defp unwrap_row(state, :engine_message, %{key_id: nil} = row) do
    case Envelope.unwrap(state.root_vault, wrapped_key(row)) do
      {:ok, descriptor} -> {:ok, descriptor}
      {:error, _error} -> {:error, {:invalid_key_descriptor, :unwrap_failed}}
    end
  end

  defp unwrap_row(_state, :engine_message, _row),
    do: {:error, {:invalid_key_descriptor, :unexpected_key_id}}

  defp unwrap_row(_state, :gcp_kms_ciphertext, %{key_id: nil}),
    do: {:error, {:invalid_key_descriptor, :missing_key_id}}

  # ADR-0005 open question 2: which of a second provider option, a delegation
  # to `Encryptor.Provider.GcpKms` or a composite provider supplies this
  # branch's client is undecided, and the module it would delegate to is not
  # shipped upstream (the record's assumption A4). Decision 5 is written so
  # that this is an answer rather than a crash.
  defp unwrap_row(_state, :gcp_kms_ciphertext, _row),
    do: {:error, {:invalid_key_descriptor, {:unsupported_wrapping_shape, "gcp_kms_ciphertext"}}}

  @spec wrapped_key(row()) :: WrappedKey.t()
  defp wrapped_key(row) do
    %WrappedKey{
      tenant_ref: row.tenant_ref,
      version: row.version,
      namespace: row.namespace,
      name: row.name,
      bits: row.bits,
      wrapped: row.wrapped
    }
  end

  @spec module_option(keyword(), atom()) :: {:ok, module()} | {:error, term()}
  defp module_option(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_config, [:provider, key]}}
      value when is_atom(value) -> {:ok, value}
      _other -> {:error, {:invalid_config, key, :not_a_module}}
    end
  end

  @spec reference_subkey(keyword()) :: {:ok, binary()} | {:error, term()}
  defp reference_subkey(opts) do
    case Keyword.get(opts, :reference_subkey) do
      nil ->
        {:error, {:missing_config, [:provider, :reference_subkey]}}

      subkey when is_binary(subkey) and byte_size(subkey) == @reference_subkey_bytes ->
        {:ok, subkey}

      _other ->
        {:error, {:invalid_config, :reference_subkey, :invalid_length}}
    end
  end

  # The table name is interpolated into a query source rather than bound as a
  # parameter - no adapter parameterizes a table - so the grammar is checked
  # here, once, at start.
  @spec table(keyword()) :: {:ok, String.t()} | {:error, term()}
  defp table(opts) do
    case Keyword.get(opts, :table, @default_table) do
      table when is_binary(table) ->
        if table =~ @table_name,
          do: {:ok, table},
          else: {:error, {:invalid_config, :table, :invalid_name}}

      _other ->
        {:error, {:invalid_config, :table, :invalid_name}}
    end
  end
end
