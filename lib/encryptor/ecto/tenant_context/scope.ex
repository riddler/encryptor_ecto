defmodule Encryptor.Ecto.TenantContext.Scope do
  @moduledoc """
  The `tenant: :scope` strategy, as an ordinary `Encryptor.Ecto.TenantContext`.

  It reads `Encryptor.Ecto.Tenant` and answers with what it finds. That is the
  whole implementation, and it is deliberately the whole implementation: the
  default strategy is not privileged (ADR-0001 decision 5f), so a host
  substituting its own resolver is replacing a module of this size rather than
  opting out of a mechanism the types treat specially.

  An empty scope resolves to `{:error, :no_tenant_in_scope}` and never to
  `:none`. The distinction is the one ADR-0001 decision 5c exists to protect:
  `:none` means "this field is global, declared so at the schema", while an
  empty scope means "nobody said" - and the second must fail loudly rather than
  write a row under a key that no tenant can shred.
  """

  @behaviour Encryptor.Ecto.TenantContext

  alias Encryptor.Ecto.Tenant

  @doc """
  Resolves the tenant from the calling process's scope.

      iex> Encryptor.Ecto.Tenant.put("merchant_7f3")
      iex> Encryptor.Ecto.TenantContext.Scope.resolve(:dump, %{
      ...>   vault: Payments.Vault,
      ...>   table: "cards",
      ...>   column: "pan"
      ...> })
      {:ok, "merchant_7f3"}

      iex> Encryptor.Ecto.Tenant.clear()
      iex> Encryptor.Ecto.TenantContext.Scope.resolve(:dump, %{
      ...>   vault: Payments.Vault,
      ...>   table: "cards",
      ...>   column: "pan"
      ...> })
      {:error, :no_tenant_in_scope}
  """
  @impl Encryptor.Ecto.TenantContext
  @spec resolve(Encryptor.Ecto.TenantContext.operation(), Encryptor.Ecto.TenantContext.params()) ::
          {:ok, String.t()} | {:error, :no_tenant_in_scope}
  def resolve(operation, params) when operation in [:dump, :load] and is_map(params) do
    case Tenant.get() do
      {:ok, tenant} -> {:ok, tenant}
      :error -> {:error, :no_tenant_in_scope}
    end
  end
end
