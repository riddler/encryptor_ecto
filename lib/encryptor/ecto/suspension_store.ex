defmodule Encryptor.Ecto.SuspensionStore do
  @moduledoc """
  A shared `Encryptor.Vault.Suspension.Store` over the host's own repo: one
  suspension reaches every node that reads the same table, and survives
  restarts.

  `encryptor`'s enc-ADR-0010 makes where a vault's suspended set is agreed a
  behaviour, ships the per-node table as its default, and leaves the shared
  store to the host (its decision 10, which also names this package as where
  a Repo-backed one would land). This module is that store. The vault reads it
  back into its per-node view on its own poll, and the gate never asks it: the
  hot path stays one table read on the node (enc-ADR-0010 decision 3).

  ## Configuring it

      config :my_app, MyApp.ScopedVault,
        suspension_store: {Encryptor.Ecto.SuspensionStore, repo: MyApp.Repo},
        suspension_poll_interval: 5_000

  | Option | | |
  |---|---|---|
  | `:repo` | required | The `Ecto.Repo` the suspension table lives in |
  | `:table` | `"encryptor_suspensions"` | The table to read and write |
  | `:prefix` | `nil` | The schema prefix the table lives in; the repo's default when absent |

  The poll interval is the vault's `:suspension_poll_interval`, not an option
  here: how often a node reads the set is the vault's decision, and this
  store answers whenever it is asked. Any other option is refused at vault
  start, which `encryptor` reports as
  `{:invalid_config, :suspension_store, :init}`.

  `c:Encryptor.Vault.Suspension.Store.init/2` opens no connection, as the
  behaviour requires. A table that was never migrated is found by the first
  call that reads it.

  ## The table

  | Column | |
  |---|---|
  | `id` | the surrogate primary key `Ecto.Migration.create/2` adds by default. This module never selects it |
  | `vault` | the vault module the set belongs to, as `inspect/1` spells it |
  | `selector` | the suspended scope's selector, as the host passed it to `Encryptor.Vault.suspend/2` |
  | `inserted_at` | when the suspension was first written, UTC. Written here and never read |

  One unique index over `{vault, selector}` makes `suspend/2` idempotent at
  the database: a second suspension of the same scope is a conflict the
  insert ignores, not a second row. It is also what keys the set by vault:
  enc-ADR-0010 decision 1 says two vaults never share a set, and two vault
  modules pointed at one table read and write disjoint rows. Renaming a vault
  module therefore starts it with an empty set; carry its rows across in the
  same deploy.

  The table arrives the way this package's other tables do, as migration
  source the host reviews and runs: `mix
  encryptor.ecto.gen.suspension_store_migration`. This package issues no DDL
  (ADR-0002 decision 9).

  **The selector is stored as the host wrote it.** The key store keeps only a
  keyed reference and never the selector, because its rows sit beside every
  ciphertext. This table cannot: `c:Encryptor.Vault.Suspension.Store.list/1`
  answers selectors, and a keyed reference cannot be turned back into one. A
  row names a scope an operator suspended, in the host's own database, and
  enc-ADR-0010 decision 8 sends an operator who needs to know which scope was
  suspended to exactly this table (ADR-0007 decision 1).

  ## What it answers

    * `c:Encryptor.Vault.Suspension.Store.suspend/2` answers `:ok` for a new
      suspension and for one already in the set, and
      `{:error, {:unsupported_selector, selector}}` for a selector that is not
      a non-empty string - `:default` included. A string column cannot hold
      `:default` apart from a scope whose selector is the string `"default"`,
      and a scoped vault, the one a suspension is for, has no `:default`
      scope to suspend.
    * `c:Encryptor.Vault.Suspension.Store.reinstate/2` answers `:ok`, including
      for a selector never suspended and for one this store cannot hold.
    * `c:Encryptor.Vault.Suspension.Store.list/1` answers this vault's rows.

  A database failure is not translated: the exception raises out of the
  callback. The vault already treats an `{:error, term}`, an exit and a raise
  from a store as one outcome - a write that changes nothing, or a refresh
  that keeps the last known set - and carries the exception in the error's
  `:engine` field (enc-ADR-0010 decision 7), so a rescue here would only
  repeat that translation and hide which exception it was.
  """

  @behaviour Encryptor.Vault.Suspension.Store

  import Ecto.Query, only: [from: 2]

  @default_table "encryptor_suspensions"
  @table_name ~r/^[a-z_][a-z0-9_]*$/
  @options [:repo, :table, :prefix]

  @typedoc "What `init/2` resolves the options into. Constant, and no connection."
  @type state :: %{
          repo: module(),
          vault: String.t(),
          table: String.t(),
          prefix: String.t() | nil
        }

  @doc """
  The table name a host gets unless it names another.

      iex> Encryptor.Ecto.SuspensionStore.default_table()
      "encryptor_suspensions"
  """
  @spec default_table() :: String.t()
  def default_table, do: @default_table

  @doc """
  Resolves the options for one vault. Opens no connection.

  Refusals: `{:unknown_options, keys}`, `{:missing_config, [:suspension_store,
  :repo]}`, and `{:invalid_config, key, reason}` for a `:repo` that is not a
  module, a `:table` that is not an unquoted identifier, or an empty
  `:prefix`.
  """
  @impl true
  @spec init(module(), keyword()) :: {:ok, state()} | {:error, term()}
  def init(vault, opts) when is_atom(vault) and is_list(opts) do
    with :ok <- known_options(opts),
         {:ok, repo} <- repo(opts),
         {:ok, table} <- table(opts),
         {:ok, prefix} <- prefix(opts) do
      {:ok, %{repo: repo, vault: inspect(vault), table: table, prefix: prefix}}
    end
  end

  @doc "Adds the selector to this vault's set. Idempotent."
  @impl true
  @spec suspend(state(), Encryptor.Error.selector()) :: :ok | {:error, term()}
  def suspend(state, selector) when is_binary(selector) and selector != "" do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {_inserted, _rows} =
      state.repo.insert_all(
        state.table,
        [[vault: state.vault, selector: selector, inserted_at: now]],
        [on_conflict: :nothing, conflict_target: [:vault, :selector]] ++ query_opts(state)
      )

    :ok
  end

  def suspend(_state, selector), do: {:error, {:unsupported_selector, selector}}

  @doc "Removes the selector from this vault's set. Idempotent, and `:ok` for one never in it."
  @impl true
  @spec reinstate(state(), Encryptor.Error.selector()) :: :ok | {:error, term()}
  def reinstate(state, selector) when is_binary(selector) do
    {_deleted, _rows} =
      state.repo.delete_all(
        from(s in state.table, where: s.vault == ^state.vault and s.selector == ^selector),
        query_opts(state)
      )

    :ok
  end

  # `suspend/2` never stores anything else, so there is nothing to remove.
  def reinstate(_state, _selector), do: :ok

  @doc "This vault's whole set, in no particular order."
  @impl true
  @spec list(state()) :: {:ok, [String.t()]} | {:error, term()}
  def list(state) do
    {:ok,
     state.repo.all(
       from(s in state.table, where: s.vault == ^state.vault, select: s.selector),
       query_opts(state)
     )}
  end

  @spec known_options(keyword()) :: :ok | {:error, term()}
  defp known_options(opts) do
    case Enum.uniq(Keyword.keys(opts) -- @options) do
      [] -> :ok
      unknown -> {:error, {:unknown_options, unknown}}
    end
  end

  @spec repo(keyword()) :: {:ok, module()} | {:error, term()}
  defp repo(opts) do
    case Keyword.get(opts, :repo) do
      nil -> {:error, {:missing_config, [:suspension_store, :repo]}}
      repo when is_atom(repo) -> {:ok, repo}
      _other -> {:error, {:invalid_config, :repo, :not_a_module}}
    end
  end

  # Interpolated into the query source rather than bound, as the key store's
  # table name is, so the grammar is checked once, here.
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

  @spec prefix(keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  defp prefix(opts) do
    case Keyword.get(opts, :prefix) do
      nil -> {:ok, nil}
      prefix when is_binary(prefix) and prefix != "" -> {:ok, prefix}
      _other -> {:error, {:invalid_config, :prefix, :invalid_name}}
    end
  end

  @spec query_opts(state()) :: keyword()
  defp query_opts(%{prefix: nil}), do: []
  defp query_opts(%{prefix: prefix}), do: [prefix: prefix]
end
