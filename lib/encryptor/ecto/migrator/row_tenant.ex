defmodule Encryptor.Ecto.Migrator.RowTenant do
  @moduledoc """
  The per-row tenant resolver the migrator installs in the params it builds.

  ADR-0002 decision 3: *the migrator installs a per-row tenant resolver in the
  params it constructs, which is ADR-0001 decision 5f (the
  `Encryptor.Ecto.TenantContext` escape hatch) used exactly as intended.* A
  rewrite declaring `tenant_from :merchant_id` reads the tenant off the row it
  is rewriting, and this module is how that value reaches the type's
  `dump/3` and `load/3`.

  ## Why the value travels in a process key

  `c:Encryptor.Ecto.TenantContext.resolve/2` is handed the field's declared
  context - vault, table, column - and nothing about the row, because a
  resolver's whole purpose in application code is to answer from somewhere
  ambient. The migrator has the value in its hand, so it puts it where the
  callback can reach it: a private key in the migrator's **own** process,
  written and restored around each row.

  Two properties make that acceptable, and both are the point:

    * it is **not** `Encryptor.Ecto.Tenant`. The migrator never calls
      `Encryptor.Ecto.Tenant.put/1`, so a pass cannot corrupt the scope of a
      process that is also doing something else, and
      `Encryptor.Ecto.MissingTenantError` stays structurally unreachable
      inside a migration for the reason decision 3 gives;
    * the write is scoped with `with_tenant/2`, which restores the prior value
      in an `after`, so an exception from a type - which is the ordinary way a
      row fails here - cannot leave a stale tenant behind for the next row.

  A rewrite declaring `tenant :none` or naming its own resolver module does
  not use this module at all: the first has no tenant and the second has one
  the plan already named.

  ## An absent or unusable tenant is an error, never a guess

  A `NULL` tenant column is `{:error, _}` rather than `:none`. The two are not
  interchangeable: `:none` means *this value has no tenant and belongs to the
  vault's single key*, and answering it for a row whose tenant column happens
  to be empty would re-encrypt that row under the wrong key, permanently. The
  type raises, the engine classifies the row, and decision 11 halts the pass -
  which is what an operator wants on row one of a plan naming the wrong
  column.

  The unusable value is reported by shape and never by content. A tenant
  selector is not plaintext, but it is a routing identifier from a column this
  package did not choose, and the migrator's reports are read in the same
  places its exceptions are.
  """

  @behaviour Encryptor.Ecto.TenantContext

  alias Encryptor.Ecto.TenantContext

  @key :encryptor_ecto_migrator_row_tenant
  @absent :__absent__

  @doc """
  Runs `fun` with `tenant` resolvable, and restores what was there before.

  The restore is in an `after`, so a raising type module - the ordinary
  failure path for a row that will not decrypt - cannot leak one row's tenant
  into the next row's encrypt.
  """
  @spec with_tenant(term(), (-> result)) :: result when result: term()
  def with_tenant(tenant, fun) when is_function(fun, 0) do
    # Read before writing: `Process.put/2` answers `nil` both for a key that
    # was absent and for one that held `nil`, and the two restore differently.
    previous = Process.get(@key, @absent)
    _ = Process.put(@key, tenant)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  @doc """
  Answers with the tenant of the row currently being rewritten.

      iex> alias Encryptor.Ecto.Migrator.RowTenant
      iex> RowTenant.with_tenant("merchant_7f3", fn -> RowTenant.resolve(:dump, %{}) end)
      {:ok, "merchant_7f3"}

      iex> Encryptor.Ecto.Migrator.RowTenant.resolve(:dump, %{})
      {:error, {:no_row_tenant, :dump}}
  """
  @impl TenantContext
  @spec resolve(TenantContext.operation(), map()) :: {:ok, String.t()} | {:error, term()}
  def resolve(operation, _params) do
    case Process.get(@key, @absent) do
      tenant when is_binary(tenant) and tenant != "" -> {:ok, tenant}
      @absent -> {:error, {:no_row_tenant, operation}}
      nil -> {:error, {:null_tenant_column, operation}}
      _other -> {:error, {:unusable_tenant_column, operation}}
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
