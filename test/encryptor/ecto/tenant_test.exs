defmodule Encryptor.Ecto.TenantTest do
  use ExUnit.Case, async: true

  alias Encryptor.Ecto.Tenant

  doctest Encryptor.Ecto.Tenant

  setup do
    on_exit(&Tenant.clear/0)
    :ok
  end

  describe "put/1 and get/0" do
    # sabotage: made put/1 return the replaced value instead of :ok -> red.
    test "put/1 returns :ok and get/0 reads the value back" do
      assert :ok = Tenant.put("merchant_7f3")
      assert {:ok, "merchant_7f3"} = Tenant.get()
    end

    # sabotage: made get/0 return {:ok, nil} for an empty scope -> red.
    test "get/0 is :error when nothing is in scope" do
      assert :error = Tenant.get()
    end

    # sabotage: made put/1 keep the first value written -> red.
    test "put/1 replaces an existing scope" do
      :ok = Tenant.put("merchant_7f3")
      :ok = Tenant.put("merchant_a19")

      assert {:ok, "merchant_a19"} = Tenant.get()
    end

    # sabotage: widened put/1's guard to accept any term -> red.
    test "put/1 refuses a non-binary tenant" do
      assert_raise FunctionClauseError, fn -> Tenant.put(:merchant_7f3) end
    end
  end

  describe "fetch!/0" do
    # sabotage: made fetch!/0 return {:ok, tenant} -> red.
    test "returns the tenant in scope" do
      :ok = Tenant.put("merchant_7f3")

      assert "merchant_7f3" = Tenant.fetch!()
    end

    # sabotage: made fetch!/0 return nil for an empty scope instead of raising -> red.
    test "raises when no tenant is in scope, naming the calls that set one" do
      error = assert_raise RuntimeError, fn -> Tenant.fetch!() end

      assert error.message =~ "no tenant in scope"
      assert error.message =~ "Encryptor.Ecto.Tenant.put/1"
      assert error.message =~ "Encryptor.Ecto.Tenant.wrap/2"
    end
  end

  describe "clear/0" do
    # sabotage: made clear/0 a no-op returning :ok -> red.
    test "removes the tenant from scope" do
      :ok = Tenant.put("merchant_7f3")

      assert :ok = Tenant.clear()
      assert :error = Tenant.get()
    end

    # sabotage: made clear/0 raise when nothing was in scope -> red.
    test "is :ok when nothing was in scope" do
      assert :ok = Tenant.clear()
    end
  end

  describe "wrap/2" do
    # sabotage: made wrap/2 return :ok instead of the function's value -> red.
    test "runs the function with the tenant in scope and returns its value" do
      assert "merchant_7f3" = Tenant.wrap("merchant_7f3", &Tenant.fetch!/0)
    end

    # sabotage: replaced the restore/1 call in the after block with clear/0 -> red.
    #
    # This is the pooled-process property from ADR-0001's Consequences: wrap/2
    # restores the prior value rather than clearing it, so a unit of work
    # nested inside another does not strip the outer one's scope.
    test "restores the previous tenant rather than clearing it" do
      :ok = Tenant.put("merchant_7f3")

      assert "merchant_a19" = Tenant.wrap("merchant_a19", &Tenant.fetch!/0)
      assert {:ok, "merchant_7f3"} = Tenant.get()
    end

    # sabotage: made restore/1's nil clause a no-op returning :ok -> red.
    test "restores an empty scope to empty rather than leaving the wrapped tenant" do
      assert :error = Tenant.get()
      assert "merchant_7f3" = Tenant.wrap("merchant_7f3", &Tenant.fetch!/0)
      assert :error = Tenant.get()
    end

    # sabotage: dropped the try/after, leaving a bare fun.() call -> red.
    test "restores the previous tenant when the function raises" do
      :ok = Tenant.put("merchant_7f3")

      assert_raise ArgumentError, fn ->
        Tenant.wrap("merchant_a19", fn -> raise ArgumentError, "signup wizard variant blew up" end)
      end

      assert {:ok, "merchant_7f3"} = Tenant.get()
    end

    # sabotage: made the inner wrap/2 clear on the way out -> red.
    test "nests" do
      result =
        Tenant.wrap("merchant_7f3", fn ->
          inner = Tenant.wrap("merchant_a19", &Tenant.fetch!/0)
          {inner, Tenant.fetch!()}
        end)

      assert {"merchant_a19", "merchant_7f3"} = result
      assert :error = Tenant.get()
    end

    # sabotage: widened wrap/2's guard to is_function(fun) -> red.
    test "refuses a function of the wrong arity" do
      assert_raise FunctionClauseError, fn ->
        Tenant.wrap("merchant_7f3", fn _tenant -> :never_run end)
      end
    end
  end

  describe "process scope" do
    # sabotage: moved put/1 and get/0 onto :persistent_term -> red (the Task
    # then saw the caller's tenant).
    #
    # ADR-0001 decision 5b: scope does not propagate, and this package does not
    # pretend it does. The test asserts the limitation, because a change that
    # made it propagate invisibly would be a change to the contract.
    test "does not cross a Task boundary" do
      :ok = Tenant.put("merchant_7f3")

      task = Task.async(&Tenant.get/0)

      assert :error = Task.await(task)
      assert {:ok, "merchant_7f3"} = Tenant.get()
    end

    # sabotage: made wrap/2 read the caller's scope instead of its argument -> red.
    test "is carried across a Task boundary by fetching and wrapping explicitly" do
      :ok = Tenant.put("merchant_7f3")
      tenant = Tenant.fetch!()

      task = Task.async(fn -> Tenant.wrap(tenant, &Tenant.get/0) end)

      assert {:ok, "merchant_7f3"} = Task.await(task)
    end

    # sabotage: moved put/1 and get/0 onto :persistent_term -> red (the two
    # processes then shared one scope).
    test "is independent between concurrent processes" do
      :ok = Tenant.put("merchant_7f3")

      other = Task.async(fn -> Tenant.wrap("merchant_a19", &Tenant.fetch!/0) end)

      assert "merchant_a19" = Task.await(other)
      assert {:ok, "merchant_7f3"} = Tenant.get()
    end
  end
end
