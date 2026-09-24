defmodule Encryptor.Ecto.KeyStore do
  @moduledoc """
  The store-backed key provider: a wrapped-key table in, key descriptors out.

  `encryptor`'s ADR-0002 decision 5 puts the Ecto-backed provider in *this*
  package because it owns a schema, a migration and a repo, and its ADR-0003
  decision 9 says the vault package defines no storage at all: the vault owns
  the six fields of `Encryptor.Envelope.WrappedKey` and nothing about where
  they live. This module is the other half - the table, the query, and the
  `Encryptor.Provider` implementation that turns rows into the descriptors a
  scoped vault builds keyrings from.

  ## Configuring it

      defmodule MyApp.ScopedVault do
        use Encryptor.Vault, otp_app: :my_app, context_profile: :scoped

        def init(config) do
          # `root_subkey/2` takes the 32 root-key *bytes*, not a vault module.
          # Expand them once and hand the same value to both keys, so the
          # provider looks for a row under the reference the vault writes.
          subkey = Encryptor.Envelope.root_subkey(root_key(), "tenant-ref")

          {:ok,
           Keyword.merge(config,
             provider:
               {Encryptor.Ecto.KeyStore,
                repo: MyApp.Repo,
                root_vault: MyApp.RootVault,
                reference_subkey: subkey},
             reference_subkey: subkey
           )}
        end

        # The pinned reference root, wherever this host keeps key material -
        # the same bytes `MyApp.RootVault` is configured with.
        defp root_key do
          :my_app
          |> Application.fetch_env!(:root_key_base64)
          |> Base.decode64!()
        end
      end

  | Option | | |
  |---|---|---|
  | `:repo` | required | The `Ecto.Repo` the wrapped-key table lives in |
  | `:root_vault` | required | The vault the wrappings were produced by. `Static` provider, `cache: false` |
  | `:reference_subkey` | required | 32 bytes: the pinned reference root expanded under `"tenant-ref"` |
  | `:table` | `"encryptor_wrapped_keys"` | The table to read |
  | `:prefix` | `nil` | The schema prefix the table lives in; the repo's default when absent |
  | `:gcp_kms` | `nil` | `Encryptor.Provider.GcpKms`'s options, for a table holding `"gcp_kms_ciphertext"` rows. Absent, such a row is refused |

  ### `:prefix` is a placement decision, and it is singular

  A host that puts the wrapped-key table in a non-default Postgres schema
  names that schema here, and every query this module issues carries it. It
  is singular for the same reason `Encryptor.Ecto.Migrator`'s is: a prefix is
  a deployment-time placement decision rather than a fact about the table, so
  a host running several schemas configures one provider per schema rather
  than asking this module to enumerate them. Nothing here reads a database
  catalog to discover one.

  The generators write no prefix into their migration source, deliberately.
  `mix ecto.migrate --prefix` is Ecto's own way to place a migration, it
  applies to the table and both indexes together, and baking the schema name
  into a file the host commits would freeze a placement decision into source
  that outlives it.

  ### `:reference_subkey` is required, and it is not an extra

  A row is found by `tenant_ref`, never by the selector: the selector is the
  host's scope identifier and putting it in a column would publish it beside
  every ciphertext, which is the whole reason `Encryptor.Envelope.scope_ref/2`
  is a keyed derivation rather than a hash. So resolving a selector to a row
  *is* that derivation, and the subkey it derives under has to be in provider
  state. It must be the same value the vault itself is configured with, or the
  provider will look for a row under one reference while the vault writes a
  header claiming another.

  ### `:gcp_kms` is the GCP branch's client, and the store keeps the read

  A table can hold rows wrapped by `Encryptor.Provider.GcpKms` beside rows
  wrapped by the root vault (ADR-0005 decision 5), and a GCP row needs a
  configured KMS client to unwrap. `:gcp_kms` is that client's configuration:
  the keyword list `Encryptor.Provider.GcpKms` documents, less the two options
  this store supplies itself.

      provider:
        {Encryptor.Ecto.KeyStore,
         repo: MyApp.Repo,
         root_vault: MyApp.RootVault,
         reference_subkey: subkey,
         gcp_kms: [
           project: "myapp-prod",
           location: "us-east1",
           key_ring: "encryptor-scope-keys",
           http_client: MyApp.KmsHttp,
           goth: MyApp.Goth
         ]}

  `:reference_subkey` is this store's own, so the two cannot disagree about
  which row a selector names. `:store` is supplied per row: a GCP row is
  unwrapped by handing `Encryptor.Provider.GcpKms.decryption_keys/2` a store
  that answers that one row, so the per-row dispatch and the "one bad row"
  rule below hold for GCP rows exactly as they do for engine messages. Naming
  either inside `:gcp_kms` is refused at start rather than silently
  overridden. The options are checked through `Encryptor.Provider.GcpKms`'s
  own `c:Encryptor.Provider.init/1` at start, so a misconfigured client fails
  the vault's boot rather than its first GCP read. The decision is this
  package's ADR-0005, "Amendment A (2026-09-24)".

  ## What it does, and the three things it will not do

  `c:Encryptor.Provider.decryption_keys/2` reads every row for the selector's
  `tenant_ref`, newest version first, and unwraps each under the root vault.
  `c:Encryptor.Provider.encryption_key/2` reads the same rows in the same
  single query and unwraps the newest one, which is the provider contract's
  "the encryption key is the current one" stated as one query rather than two.

  ### One bad row is not the whole store

  The two callbacks share the query and part company on what a row that will
  not unwrap means to each of them, because it does not mean the same thing.

  `c:Encryptor.Provider.encryption_key/2` unwraps the newest row and no
  other. A wrapping four rotations old that no longer opens - a root rotation
  the rewrap pass has not finished, a row somebody edited, a shape this build
  cannot serve - says nothing about whether this scope can be written to,
  and blocking every write for the scope on it would turn one stale row into
  an outage. The newest row is the one a write is going to be encrypted
  under, so it is the only one a write's answer may depend on.

  `c:Encryptor.Provider.decryption_keys/2` skips the rows that do not unwrap
  and answers with the ones that do, newest first. The list is a candidate
  list: a version missing from it is a version the vault cannot decrypt
  under, and that is already true of a row that will not unwrap. Halting on
  the first failure instead would make *every* stored value for the scope
  unreadable to protect the subset written under the one bad version, which
  is the outage again, in the other direction.

  When no row unwraps there is nothing to answer with, and the failure of the
  newest row is returned - the same term, for the same row, that a store
  holding only that row has always returned. So the arms below are unchanged
  for a scope whose rows are all bad, and a partially-broken scope now
  keeps the half that works.

  A consequence worth naming: during a partial root rotation
  `c:Encryptor.Provider.encryption_key/2` can fail while
  `c:Encryptor.Provider.decryption_keys/2` succeeds with the older versions.
  That is the honest report - reads work, and a write must not go under a
  key this store cannot vouch for - and it is why the encryption key is not
  described here as "the head of the decryption list" any more.

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

  It **adds no cache**. The scoped vault's materials cache already collapses
  provider round trips to one per partition per `max_age`, and the provider
  contract names a second unbounded cache as the thing not to add.

  ## The table

  | Column | |
  |---|---|
  | `id` | the surrogate primary key `Ecto.Migration.create/2` adds by default. This module never selects it |
  | `tenant_ref` | `Encryptor.Envelope.scope_ref/2` of the host's selector. The lookup key. The column keeps the name it had before the scope rename, because it exists in every adopter's database; `rows/3` selects it as `:scope_ref` (ADR-0006 decision 3) |
  | `version` | the key version. Ordering is the store's job, per ADR-0002 decision 4 |
  | `namespace`, `name` | what the encrypted data key matches on, byte for byte |
  | `bits` | `256` on this path |
  | `wrapped` | the wrapping, whose kind the next column names |
  | `wrapping_shape` | which kind of wrapping `wrapped` holds: `"engine_message"` or `"gcp_kms_ciphertext"` |
  | `key_id` | `NULL` for an engine message; the `CryptoKey` id a GCP ciphertext was produced under |
  | `inserted_at`, `updated_at` | nullable `:utc_datetime` timestamps the generator emits. This module neither writes nor reads them |

  The generated DDL is those eleven columns and nothing else - see the
  migration the `mix encryptor.ecto.gen.key_store_migration` task writes. The
  timestamps are nullable and carry no default because this package writes no
  rows: a host that inserts them gets them, and one that does not gets `NULL`
  rather than a `NOT NULL` violation on its own insert.

  `wrapping_shape` and `key_id` are ADR-0005's, and they are the reason a
  reader never guesses.
  Both wrapping kinds are opaque binaries, so a reader that picks the wrong
  unwrap path gets a failure indistinguishable from a wrong key - one `varchar`
  per row removes the guess. The vocabulary is closed at those two values here,
  by that record, rather than by a database enum: this module queries the table
  schemalessly and names no adapter, so a third value is an amendment to the
  record and a clause in this module, not a migration on every adopter.

  Two unique indexes carry properties nothing at runtime can:

    * `{tenant_ref, version}` closes the race ADR-0003 leaves to this package -
      "calling `provision/3` twice concurrently for one scope can produce two
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

  Where either callback answers at all, it answers in
  `t:Encryptor.Provider.reason/0` and nothing else. The conditions that are
  not answers - a store configured wrong - raise instead, and "The failure
  that is not in the vocabulary" below is that case.

    * `{:unknown_key, selector}` - no row for this selector's `tenant_ref`. A
      settled negative answer, and the same answer for a selector a scoped
      store cannot have a reference for at all (`:default`, `""`).
    * `{:key_unavailable, selector}` - the store could not be asked, *and
      asking again later could work*. The repo is not started, the connection
      pool is exhausted, the server is shutting down or refusing connections,
      the query was cancelled. This is the one a caller retries, and telling
      it apart from the row genuinely being absent is why the provider
      contract carves both out of the decrypt path's collapse to
      `:decrypt_failed`.
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
      "gcp_kms_ciphertext"}}` - a well-formed GCP row in a store configured
      without `:gcp_kms`. The branch has no client to unwrap with, so it
      answers rather than crashes. A store with no GCP-shaped rows never
      reaches it.

  None of those five widens `t:Encryptor.Provider.reason/0`: they are new terms
  inside `{:invalid_key_descriptor, term()}`, which is open by construction.

  A GCP row in a store configured *with* `:gcp_kms` answers whatever
  `Encryptor.Provider.GcpKms` answers for that row, unrelabelled. Its
  `Decrypt` failing - the service unreachable, or the row's `tenant_ref`,
  `version` or `namespace` no longer matching the data its wrapping was bound
  to - is `{:key_unavailable, selector}`, because the provider does not tell
  those apart and this store cannot either; a stored row it would never have
  written is `{:invalid_key_descriptor, :invalid_row}`.

  ## The failure that is not in the vocabulary

  A store that was configured wrong does not answer at all: the exception
  raises out of the callback, unchanged.

  `t:Encryptor.Provider.reason/0` is a closed vocabulary and this package does
  not get to widen it, so there is no term here for "the table was never
  migrated", "`:repo` is not a repo" or "the columns are not the ones this
  version reads". Reporting those as `{:key_unavailable, selector}` - which is
  what a bare `rescue` did - is worse than having no term: it tells an
  operator to wait for a transient condition to clear, and it never clears. A
  host that forgot the migration would get `key_unavailable` for that scope
  forever, and the `Postgrex.Error` naming the missing table would be dropped
  on the floor.

  So the rescue is narrowed to the conditions a retry can actually resolve,
  and everything else keeps its own exception - `Postgrex.Error` with
  `undefined_table` or `undefined_column`, `UndefinedFunctionError` for a
  `:repo` that is not one. Those are deploy-time mistakes, they are permanent
  until somebody changes something, and a loud crash naming the real cause is
  the report they deserve. Nothing about this is a reason a caller matches on;
  it is the absence of one.

  Records: `encryptor` ADR-0002 decisions 4, 5 and 6; ADR-0003 decisions 1, 3,
  4 and 9; this package's ADR-0002 decision 9 and ADR-0005.
  """

  @behaviour Encryptor.Provider

  import Ecto.Query, only: [from: 2]

  alias Encryptor.Envelope
  alias Encryptor.Envelope.WrappedKey
  alias Encryptor.Key.Aes
  alias Encryptor.Provider
  alias Encryptor.Provider.GcpKms

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
          table: String.t(),
          prefix: String.t() | nil,
          gcp_kms: keyword() | nil
        }

  @typedoc "One row of the wrapped-key table, as selected by `rows/3`."
  @type row :: %{
          scope_ref: String.t(),
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
         {:ok, table} <- table(opts),
         {:ok, prefix} <- prefix(opts),
         {:ok, gcp_kms} <- gcp_kms(opts, subkey) do
      {:ok,
       %{
         repo: repo,
         root_vault: root_vault,
         reference_subkey: subkey,
         table: table,
         prefix: prefix,
         gcp_kms: gcp_kms
       }}
    end
  end

  @doc """
  The newest live version for this selector.

  The same single query `c:Encryptor.Provider.decryption_keys/2` runs, so the
  two cannot disagree about which version is current - but only the newest
  row is unwrapped. An older wrapping that no longer opens is not a reason a
  scope cannot be written to, and the moduledoc's "one bad row is not the
  whole store" says why at length.
  """
  @impl Provider
  @spec encryption_key(state(), Provider.selector()) ::
          {:ok, Aes.t()} | {:error, Provider.reason()}
  def encryption_key(state, selector) do
    with {:ok, ref} <- scope_ref(state, selector),
         {:ok, [newest | _older]} <- rows(state, ref, selector) do
      descriptor(state, newest, selector)
    else
      {:ok, []} -> {:error, {:unknown_key, selector}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Every live version for this selector, newest first.

  Dropping a row from the table is what removes an entry from this list, and
  that is the crypto-shred mechanism rather than a cleanup. A row that will
  not unwrap is skipped rather than fatal, for the reasons the moduledoc's
  "one bad row is not the whole store" gives; the error arrives only when no
  row unwrapped at all.
  """
  @impl Provider
  @spec decryption_keys(state(), Provider.selector()) ::
          {:ok, [Aes.t(), ...]} | {:error, Provider.reason()}
  def decryption_keys(state, selector) do
    with {:ok, ref} <- scope_ref(state, selector),
         {:ok, rows} <- rows(state, ref, selector) do
      unwrap_all(state, rows, selector)
    end
  end

  # A selector a scope reference cannot be derived from - `:default`, an empty
  # string - is not a store failure and not a caller retrying into success. It
  # is a selector this provider does not serve, which is what `:unknown_key`
  # means, and it is the arm `Encryptor.Provider.Conformance` holds every
  # adapter to.
  @spec scope_ref(state(), Provider.selector()) ::
          {:ok, String.t()} | {:error, Provider.reason()}
  defp scope_ref(state, selector) do
    case Envelope.scope_ref(state.reference_subkey, selector) do
      {:ok, ref} -> {:ok, ref}
      {:error, _error} -> {:error, {:unknown_key, selector}}
    end
  end

  # The whole candidate list in one query, ordered by the store because
  # ordering information is the store's and not the struct's.
  #
  # The rescue is not a rescue-to-default: it is the translation an exception
  # needs to become the event the provider contract requires. `repo.all/2`
  # raises when the repo is not started and when the pool cannot answer, and
  # both of those are `:key_unavailable` - the reason a caller retries. The
  # exception itself is dropped rather than carried, for the reason the
  # moduledoc gives.
  #
  # It is narrow on purpose. An exception `transient?/1` does not recognize is
  # re-raised with its original stacktrace rather than translated, because
  # `{:key_unavailable, selector}` is a promise that retrying might help and a
  # missing table never stops missing. The moduledoc's "the failure that is
  # not in the vocabulary" is the whole argument.
  @spec rows(state(), String.t(), Provider.selector()) ::
          {:ok, [map()]} | {:error, Provider.reason()}
  defp rows(state, ref, selector) do
    query =
      from(k in state.table,
        where: k.tenant_ref == ^ref,
        order_by: [desc: k.version],
        select: %{
          scope_ref: k.tenant_ref,
          version: k.version,
          namespace: k.namespace,
          name: k.name,
          bits: k.bits,
          wrapped: k.wrapped,
          wrapping_shape: k.wrapping_shape,
          key_id: k.key_id
        }
      )

    {:ok, state.repo.all(query, query_opts(state))}
  rescue
    exception ->
      if transient?(exception),
        do: {:error, {:key_unavailable, selector}},
        else: reraise(exception, __STACKTRACE__)
  end

  # `:prefix` is passed as a query option rather than spelled into the query
  # source, which is what lets the adapter quote it - the same shape
  # `Encryptor.Ecto.Migrator.Pass` passes its own prefix in.
  @spec query_opts(state()) :: keyword()
  defp query_opts(%{prefix: nil}), do: []
  defp query_opts(%{prefix: prefix}), do: [prefix: prefix]

  # Matched as bare maps rather than as struct literals: `postgrex` and
  # `db_connection` are `only: :test` dependencies of this package, so naming
  # `%Postgrex.Error{}` here would not compile in a host's build. The atom in
  # a map pattern needs no module.
  #
  # A `Postgrex.Error` that carries no `:postgres` map never reached the
  # server at all, which is the connection being gone. One that does carries
  # the server's own verdict, and only the codes below describe a condition
  # that can clear on its own - `undefined_table`, `undefined_column`,
  # `invalid_schema_name` and `insufficient_privilege` are all deploy-time
  # mistakes and deliberately absent.
  @transient_postgres_codes [
    :admin_shutdown,
    :cannot_connect_now,
    :configuration_limit_exceeded,
    :connection_does_not_exist,
    :connection_failure,
    :crash_shutdown,
    :deadlock_detected,
    :disk_full,
    :idle_session_timeout,
    :insufficient_resources,
    :lock_not_available,
    :out_of_memory,
    :query_canceled,
    :serialization_failure,
    :sqlclient_unable_to_establish_sqlconnection,
    :sqlserver_rejected_establishment_of_sqlconnection,
    :too_many_connections
  ]

  # `Ecto.Repo.Registry` raises this, and only this, for a repo whose
  # supervisor has not come up. It reads "or it does not exist" too, and a
  # repo module that was never started and one that will never exist are
  # genuinely indistinguishable from here - so the arm a retry might resolve
  # is the one taken.
  @unstarted_repo "could not lookup Ecto repo"

  @spec transient?(Exception.t()) :: boolean()
  defp transient?(%{__struct__: DBConnection.ConnectionError}), do: true

  defp transient?(%{__struct__: Postgrex.Error, postgres: %{code: code}}),
    do: code in @transient_postgres_codes

  defp transient?(%{__struct__: Postgrex.Error}), do: true

  defp transient?(%RuntimeError{message: message}) when is_binary(message),
    do: String.contains?(message, @unstarted_repo)

  defp transient?(_exception), do: false

  # Every row is attempted and the failures are set aside rather than halted
  # on: the candidate list is what a stored message might have been written
  # under, and a version that will not unwrap is already not a version
  # anything can be decrypted under. The reason kept is the *newest* failing
  # row's, because `rows/3` orders newest first and a store whose only row is
  # bad has to keep answering exactly what it answered before this split.
  @spec unwrap_all(state(), [row()], Provider.selector()) ::
          {:ok, [Aes.t(), ...]} | {:error, Provider.reason()}
  defp unwrap_all(_state, [], selector), do: {:error, {:unknown_key, selector}}

  defp unwrap_all(state, rows, selector) do
    {descriptors, reasons} =
      rows
      |> Enum.map(&descriptor(state, &1, selector))
      |> Enum.split_with(&match?({:ok, _descriptor}, &1))

    case descriptors do
      [_ | _] -> {:ok, Enum.map(descriptors, fn {:ok, descriptor} -> descriptor end)}
      [] -> hd(reasons)
    end
  end

  # ADR-0005 decision 5: the dispatch is per row and at read time, never per
  # store. A host moving one scope's wrapping from a root vault to GCP KMS has
  # a table holding both shapes at once for the length of that migration, and a
  # per-store setting would make the mixed window unrepresentable.
  @spec descriptor(state(), row(), Provider.selector()) ::
          {:ok, Aes.t()} | {:error, Provider.reason()}
  defp descriptor(state, row, selector) do
    with {:ok, shape} <- shape(row.wrapping_shape), do: unwrap_row(state, shape, row, selector)
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
  @spec unwrap_row(state(), wrapping_shape(), row(), Provider.selector()) ::
          {:ok, Aes.t()} | {:error, Provider.reason()}
  defp unwrap_row(state, :engine_message, %{key_id: nil} = row, _selector) do
    case Envelope.unwrap(state.root_vault, wrapped_key(row)) do
      {:ok, descriptor} -> {:ok, descriptor}
      {:error, _error} -> {:error, {:invalid_key_descriptor, :unwrap_failed}}
    end
  end

  defp unwrap_row(_state, :engine_message, _row, _selector),
    do: {:error, {:invalid_key_descriptor, :unexpected_key_id}}

  defp unwrap_row(_state, :gcp_kms_ciphertext, %{key_id: nil}, _selector),
    do: {:error, {:invalid_key_descriptor, :missing_key_id}}

  # ADR-0005 Amendment A: a store configured without `:gcp_kms` has no client
  # for this branch, and decision 5 is written so that this is an answer
  # rather than a crash.
  defp unwrap_row(%{gcp_kms: nil}, :gcp_kms_ciphertext, _row, _selector),
    do: {:error, {:invalid_key_descriptor, {:unsupported_wrapping_shape, "gcp_kms_ciphertext"}}}

  # ADR-0005 Amendment A: the delegation. `Encryptor.Provider.GcpKms` has no
  # public single-row unwrap, so the row is handed to its public
  # `decryption_keys/2` through a store that answers this one row and nothing
  # else. Its answer is returned unrelabelled - the provider's reasons are
  # already `t:Encryptor.Provider.reason/0`.
  defp unwrap_row(state, :gcp_kms_ciphertext, row, selector) do
    provisioned = Map.delete(row, :wrapping_shape)
    opts = Keyword.put(state.gcp_kms, :store, fn _scope_ref -> {:ok, [provisioned]} end)

    with {:ok, gcp_state} <- GcpKms.init(opts),
         {:ok, [descriptor]} <- GcpKms.decryption_keys(gcp_state, selector) do
      {:ok, descriptor}
    end
  end

  @spec wrapped_key(row()) :: WrappedKey.t()
  defp wrapped_key(row) do
    %WrappedKey{
      scope_ref: row.scope_ref,
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

  # ADR-0005 Amendment A. The two options this store supplies are refused
  # rather than overridden: a host that names its own `:reference_subkey` here
  # believes it configured something, and a silent override would hide that it
  # did not. The rest is checked by `Encryptor.Provider.GcpKms.init/1` itself,
  # once, now, with a store that answers nothing - so the client's own refusal
  # terms reach the host unchanged, at vault start.
  @gcp_kms_supplied [:reference_subkey, :store]

  @spec gcp_kms(keyword(), binary()) :: {:ok, keyword() | nil} | {:error, term()}
  defp gcp_kms(opts, subkey) do
    case Keyword.get(opts, :gcp_kms) do
      nil ->
        {:ok, nil}

      gcp_opts when is_list(gcp_opts) ->
        if Keyword.keyword?(gcp_opts),
          do: gcp_kms_opts(gcp_opts, subkey),
          else: {:error, {:invalid_config, :gcp_kms, :not_a_keyword_list}}

      _other ->
        {:error, {:invalid_config, :gcp_kms, :not_a_keyword_list}}
    end
  end

  @spec gcp_kms_opts(keyword(), binary()) :: {:ok, keyword()} | {:error, term()}
  defp gcp_kms_opts(gcp_opts, subkey) do
    case Enum.find(@gcp_kms_supplied, &Keyword.has_key?(gcp_opts, &1)) do
      nil ->
        resolved = Keyword.put(gcp_opts, :reference_subkey, subkey)

        with {:ok, _checked} <- GcpKms.init(Keyword.put(resolved, :store, &no_rows/1)),
             do: {:ok, resolved}

      supplied ->
        {:error, {:invalid_config, :gcp_kms, {:supplied_by_key_store, supplied}}}
    end
  end

  @spec no_rows(String.t()) :: {:ok, []}
  defp no_rows(_scope_ref), do: {:ok, []}

  # A prefix goes to the adapter as a query option, which quotes it, so it
  # needs no identifier grammar the way the interpolated table name does -
  # only to be absent or a real name. An empty string is refused rather than
  # treated as absent: it would read as "the default schema" while saying
  # something was configured.
  @spec prefix(keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  defp prefix(opts) do
    case Keyword.get(opts, :prefix) do
      nil -> {:ok, nil}
      prefix when is_binary(prefix) and prefix != "" -> {:ok, prefix}
      _other -> {:error, {:invalid_config, :prefix, :invalid_name}}
    end
  end
end
