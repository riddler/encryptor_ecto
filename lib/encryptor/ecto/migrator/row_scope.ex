defmodule Encryptor.Ecto.Migrator.RowScope do
  @moduledoc """
  The per-row scope resolver the migrator installs in the params it builds.

  ADR-0002 decision 3: *the migrator installs a per-row scope resolver in the
  params it constructs, which is ADR-0001 decision 5f (the
  `Encryptor.Ecto.ScopeContext` escape hatch) used exactly as intended.* A
  rewrite declaring `scope_from :merchant_id` reads the scope off the row it
  is rewriting, and this module is how that value reaches the type's
  `dump/3` and `load/3`.

  ## Why the value travels in a process key

  `c:Encryptor.Ecto.ScopeContext.resolve/2` is handed the field's declared
  context - vault, table, column - and nothing about the row, because a
  resolver's whole purpose in application code is to answer from somewhere
  ambient. The migrator has the value in its hand, so it puts it where the
  callback can reach it: a private key in the migrator's **own** process,
  written and restored around each row.

  Two properties make that acceptable, and both are the point:

    * it is **not** `Encryptor.Ecto.Scope`. The migrator never calls
      `Encryptor.Ecto.Scope.put/1`, so a pass cannot corrupt the scope of a
      process that is also doing something else, and
      `Encryptor.Ecto.MissingScopeError` stays structurally unreachable
      inside a migration for the reason decision 3 gives;
    * the write is scoped with `with_scope/2`, which restores the prior value
      in an `after`, so an exception from a type - which is the ordinary way a
      row fails here - cannot leave a stale scope behind for the next row.

  A rewrite declaring `scope :none` or naming its own resolver module does
  not use this module at all: the first has no scope and the second has one
  the plan already named.

  ## An absent or unusable scope is an error, never a guess

  A `NULL` scope column is `{:error, _}` rather than `:none`. The two are not
  interchangeable: `:none` means *this value has no scope and belongs to the
  vault's single key*, and answering it for a row whose scope column happens
  to be empty would re-encrypt that row under the wrong key, permanently. The
  type raises, the engine classifies the row, and decision 11 halts the pass -
  which is what an operator wants on row one of a plan naming the wrong
  column.

  The unusable value is reported by shape and never by content. A scope
  selector is not plaintext, but it is a routing identifier from a column this
  package did not choose, and the migrator's reports are read in the same
  places its exceptions are.
  """

  @behaviour Encryptor.Ecto.ScopeContext

  alias Encryptor.Ecto.ScopeContext

  @key :encryptor_ecto_migrator_row_scope
  @absent :__absent__

  @doc """
  Runs `fun` with `scope` resolvable, and restores what was there before.

  The restore is in an `after`, so a raising type module - the ordinary
  failure path for a row that will not decrypt - cannot leak one row's scope
  into the next row's encrypt.
  """
  @spec with_scope(term(), (-> result)) :: result when result: term()
  def with_scope(scope, fun) when is_function(fun, 0) do
    # Read before writing: `Process.put/2` answers `nil` both for a key that
    # was absent and for one that held `nil`, and the two restore differently.
    previous = Process.get(@key, @absent)
    _ = Process.put(@key, scope)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  @doc """
  Answers with the scope of the row currently being rewritten.

      iex> alias Encryptor.Ecto.Migrator.RowScope
      iex> RowScope.with_scope("merchant_7f3", fn -> RowScope.resolve(:dump, %{}) end)
      {:ok, "merchant_7f3"}

      iex> Encryptor.Ecto.Migrator.RowScope.resolve(:dump, %{})
      {:error, {:no_row_scope, :dump}}
  """
  @impl ScopeContext
  @spec resolve(ScopeContext.operation(), map()) :: {:ok, String.t()} | {:error, term()}
  def resolve(operation, _params) do
    case Process.get(@key, @absent) do
      scope when is_binary(scope) and scope != "" -> {:ok, scope}
      @absent -> {:error, {:no_row_scope, operation}}
      nil -> {:error, {:null_scope_column, operation}}
      _other -> {:error, {:unusable_scope_column, operation}}
    end
  end

  @spec restore(term()) :: :ok
  defp restore(@absent), do: delete()
  defp restore(previous), do: put(previous)

  @spec delete() :: :ok
  defp delete do
    _ = Process.delete(@key)
    :ok
  end

  @spec put(term()) :: :ok
  defp put(value) do
    _ = Process.put(@key, value)
    :ok
  end
end
