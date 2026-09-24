defmodule Encryptor.Ecto.ScopeContext.Process do
  @moduledoc """
  The `scope: :process` strategy, as an ordinary `Encryptor.Ecto.ScopeContext`.

  It reads `Encryptor.Ecto.Scope` and answers with what it finds. That is the
  whole implementation, and it is deliberately the whole implementation: the
  default strategy is not privileged (ADR-0001 decision 5f), so a host
  substituting its own resolver is replacing a module of this size rather than
  opting out of a mechanism the types treat specially.

  An empty scope resolves to `{:error, :no_scope_in_process}` and never to
  `:none`. The distinction is the one ADR-0001 decision 5c exists to protect:
  `:none` means "this field is global, declared so at the schema", while an
  empty scope means "nobody said" - and the second must fail loudly rather than
  write a row under a key that no scope can shred.
  """

  @behaviour Encryptor.Ecto.ScopeContext

  alias Encryptor.Ecto.Scope

  @doc """
  Resolves the scope set in the calling process.

      iex> Encryptor.Ecto.Scope.put("merchant_7f3")
      iex> Encryptor.Ecto.ScopeContext.Process.resolve(:dump, %{
      ...>   vault: Payments.Vault,
      ...>   table: "cards",
      ...>   column: "pan"
      ...> })
      {:ok, "merchant_7f3"}

      iex> Encryptor.Ecto.Scope.clear()
      iex> Encryptor.Ecto.ScopeContext.Process.resolve(:dump, %{
      ...>   vault: Payments.Vault,
      ...>   table: "cards",
      ...>   column: "pan"
      ...> })
      {:error, :no_scope_in_process}
  """
  @impl Encryptor.Ecto.ScopeContext
  @spec resolve(Encryptor.Ecto.ScopeContext.operation(), Encryptor.Ecto.ScopeContext.params()) ::
          {:ok, String.t()} | {:error, :no_scope_in_process}
  def resolve(operation, params) when operation in [:dump, :load] and is_map(params) do
    case Scope.get() do
      {:ok, scope} -> {:ok, scope}
      :error -> {:error, :no_scope_in_process}
    end
  end
end
