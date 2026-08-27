defmodule Encryptor.Ecto.TenantContext.ScopeTest do
  use ExUnit.Case, async: true

  alias Encryptor.Ecto.Tenant
  alias Encryptor.Ecto.TenantContext.Scope

  doctest Encryptor.Ecto.TenantContext.Scope

  defmodule StaticResolver do
    @moduledoc false

    @behaviour Encryptor.Ecto.TenantContext

    @impl Encryptor.Ecto.TenantContext
    def resolve(:dump, %{table: "cards"}), do: {:ok, "merchant_a19"}
    def resolve(:load, %{table: "cards"}), do: {:ok, "merchant_a19"}
    def resolve(_operation, %{table: "signup_wizard_variants"}), do: :none
    def resolve(_operation, _params), do: {:error, :unknown_field}
  end

  @params %{vault: Payments.Vault, table: "cards", column: "pan"}

  setup do
    on_exit(&Tenant.clear/0)
    :ok
  end

  # A call site that knows only the behaviour. Substituting a resolver for
  # :scope is a change to which module is named, and to nothing else.
  defp resolve_through(resolver, operation, params), do: resolver.resolve(operation, params)

  describe "resolve/2" do
    # sabotage: made resolve/2 always answer {:error, :no_tenant_in_scope} -> red.
    test "answers with the tenant in scope" do
      :ok = Tenant.put("merchant_7f3")

      assert {:ok, "merchant_7f3"} = Scope.resolve(:dump, @params)
      assert {:ok, "merchant_7f3"} = Scope.resolve(:load, @params)
    end

    # sabotage: made an empty scope resolve to :none -> red.
    #
    # :none means "declared global"; an empty scope means "nobody said". A
    # resolver that conflated them would write a row nobody can shred.
    test "reports an empty scope as an error and never as :none" do
      assert {:error, :no_tenant_in_scope} = Scope.resolve(:dump, @params)
      assert {:error, :no_tenant_in_scope} = Scope.resolve(:load, @params)
    end

    # sabotage: dropped the operation guard -> red.
    test "refuses an operation that is neither :dump nor :load" do
      :ok = Tenant.put("merchant_7f3")

      assert_raise FunctionClauseError, fn -> Scope.resolve(:cast, @params) end
    end

    # sabotage: made resolve/2 answer with the params' table instead of the
    # process scope -> red.
    test "ignores the declared context and reads only the scope" do
      :ok = Tenant.put("merchant_7f3")

      other = %{vault: Payments.OtherVault, table: "signup_wizard_variants", column: "assignment"}

      assert {:ok, "merchant_7f3"} = Scope.resolve(:dump, other)
    end
  end

  describe "substitutability" do
    # sabotage: removed the @behaviour attribute from Scope -> red.
    test "the default :scope strategy is an implementation of the behaviour" do
      assert Encryptor.Ecto.TenantContext in Scope.__info__(:attributes)[:behaviour]
    end

    # sabotage: made Scope.resolve/2 answer a fixed tenant -> red.
    test "a host resolver is called through the same call site as :scope" do
      :ok = Tenant.put("merchant_7f3")

      assert {:ok, "merchant_7f3"} = resolve_through(Scope, :dump, @params)
      assert {:ok, "merchant_a19"} = resolve_through(StaticResolver, :dump, @params)
    end

    # sabotage: made StaticResolver's :none clause return {:ok, nil} -> red.
    test "a resolver may answer :none for a field it declares global" do
      params = %{vault: Payments.Vault, table: "signup_wizard_variants", column: "assignment"}

      assert :none = resolve_through(StaticResolver, :dump, params)
    end

    # sabotage: made StaticResolver's catch-all clause return :none -> red.
    test "a resolver's error reason reaches the call site unchanged" do
      params = %{vault: Payments.Vault, table: "ledger_entries", column: "memo"}

      assert {:error, :unknown_field} = resolve_through(StaticResolver, :load, params)
    end
  end
end
