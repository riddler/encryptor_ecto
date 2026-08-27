defmodule Encryptor.Ecto.TenantScopeTest do
  use ExUnit.Case, async: true

  import Encryptor.Ecto.TenantScope, only: [scope_tenant: 1]

  alias Encryptor.Ecto.Tenant
  alias Encryptor.Ecto.TenantScope

  doctest Encryptor.Ecto.TenantScope

  describe "scope_tenant/1 inside a describe block" do
    scope_tenant "merchant_7f3"

    # sabotage: made the macro expand to `setup_all` -> red, because a
    # setup_all callback runs in a different process from the test.
    test "puts the named tenant in scope for each test in the block" do
      assert {:ok, "merchant_7f3"} = Tenant.get()
    end

    # sabotage: stored the scope in :persistent_term rather than the process
    # dictionary -> red, because the scope would then propagate.
    test "scopes the test process only; work the test spawns does not inherit it" do
      task = Task.async(&Tenant.get/0)

      assert :error = Task.await(task)
    end

    # sabotage: made wrap/2 clear rather than restore -> red.
    test "wrap/2 nests inside the scoped tenant and restores it" do
      assert "merchant_a19" = Tenant.wrap("merchant_a19", &Tenant.fetch!/0)
      assert {:ok, "merchant_7f3"} = Tenant.get()
    end
  end

  describe "a describe block with no scope_tenant call" do
    # sabotage: stored the scope in :persistent_term rather than the process
    # dictionary -> red, because the block above would leak its tenant here.
    test "has no tenant in scope, and the helper installs no default" do
      assert :error = Tenant.get()
    end
  end

  describe "put_tenant/1" do
    # sabotage: made put_tenant/1 return the previous scope -> red.
    test "returns :ok and puts the tenant in scope" do
      assert :ok = TenantScope.put_tenant("merchant_7f3")
      assert {:ok, "merchant_7f3"} = Tenant.get()
    end

    # sabotage: made the fallback install a default tenant rather than raise
    # -> red, which is the whole failure this helper is not allowed to have.
    test "refuses a non-binary tenant, saying it substitutes no default" do
      error = assert_raise ArgumentError, fn -> TenantScope.put_tenant(:merchant_7f3) end

      assert error.message =~ "expected a non-empty tenant identifier"
      assert error.message =~ "never substitutes a default tenant"
    end

    # sabotage: relaxed the guard to plain is_binary/1 -> red.
    test "refuses an empty tenant identifier" do
      assert_raise ArgumentError, fn -> TenantScope.put_tenant("") end
    end

    # sabotage: made put_tenant/1 return :error for a valid tenant -> red,
    # because ExUnit rejects the setup return value.
    test "is usable directly as an ExUnit setup callback" do
      assert :ok = TenantScope.put_tenant("merchant_7f3")
    end
  end
end

defmodule Encryptor.Ecto.TenantScopeCaseTest do
  use ExUnit.Case, async: true

  import Encryptor.Ecto.TenantScope, only: [scope_tenant: 1]

  alias Encryptor.Ecto.Tenant

  scope_tenant "merchant_7f3"

  # sabotage: made the macro expand to `setup_all` -> red, for the same reason
  # as the describe-scoped case: the tenant would be in the wrong process.
  test "a case-level call scopes every test in the case" do
    assert {:ok, "merchant_7f3"} = Tenant.get()
  end

  # sabotage: had put_tenant/1 write to :persistent_term -> red, because the
  # spawned task would then see a tenant it was never handed.
  test "and does not leak the scope out of the test process" do
    assert {:ok, "merchant_7f3"} = Tenant.get()
    assert :error = Task.await(Task.async(&Tenant.get/0))
  end
end
