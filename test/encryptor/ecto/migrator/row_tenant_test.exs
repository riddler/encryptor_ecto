defmodule Encryptor.Ecto.Migrator.RowTenantTest do
  @moduledoc """
  The resolver the migrator installs for a `tenant_from` rewrite.

  The interesting cases are all about what happens *between* rows: a scope
  that is restored after a raise, and an absent or empty tenant that is an
  error rather than the `:none` that would re-encrypt the row under the wrong
  key.
  """

  use ExUnit.Case, async: true

  alias Encryptor.Ecto.Migrator.RowTenant
  alias Encryptor.Ecto.Tenant

  describe "resolve/2" do
    # Sabotage: made the absent arm answer `:none` - a row visited with no
    # tenant installed was encrypted under the vault's single key instead of
    # failing, which is the permanent wrong-key write the arm exists to
    # prevent.
    test "an absent tenant is an error naming the operation" do
      assert {:error, {:no_row_tenant, :dump}} = RowTenant.resolve(:dump, %{})
    end

    # Sabotage: made the `nil` arm answer `:none` - a row whose tenant column
    # was NULL migrated silently under the wrong key.
    test "a NULL tenant column is an error, not :none" do
      RowTenant.with_tenant(nil, fn ->
        assert {:error, {:null_tenant_column, :load}} = RowTenant.resolve(:load, %{})
      end)
    end

    # Sabotage: dropped the `tenant != ""` guard - an empty tenant column
    # resolved to `""` and the vault was asked for a key nobody named.
    test "an empty tenant column is an error" do
      RowTenant.with_tenant("", fn ->
        assert {:error, {:unusable_tenant_column, :dump}} = RowTenant.resolve(:dump, %{})
      end)
    end

    # Sabotage: made the catch-all render the value - a tenant selector from a
    # column this package did not choose reached a failure report.
    test "a tenant of another shape is reported by shape only" do
      RowTenant.with_tenant(42, fn ->
        assert {:error, reason} = RowTenant.resolve(:dump, %{})
        refute inspect(reason) =~ "42"
      end)
    end
  end

  describe "with_tenant/2" do
    # Sabotage: dropped the `after` - a type raising on one row left that
    # row's tenant installed for the next one, which is a wrong-key encrypt
    # produced by an error path.
    test "restores the previous value even when the function raises" do
      assert_raise RuntimeError, fn ->
        RowTenant.with_tenant("merchant_7f3", fn -> raise "boom" end)
      end

      assert {:error, {:no_row_tenant, :dump}} = RowTenant.resolve(:dump, %{})
    end

    # Sabotage: read the previous value with `Process.put/2`'s return instead
    # of a `get` - an outer row's tenant was deleted rather than restored on
    # the way out of a nested call.
    test "nested calls restore the outer row's tenant" do
      RowTenant.with_tenant("merchant_7f3", fn ->
        RowTenant.with_tenant("merchant_a19", fn ->
          assert {:ok, "merchant_a19"} = RowTenant.resolve(:dump, %{})
        end)

        assert {:ok, "merchant_7f3"} = RowTenant.resolve(:dump, %{})
      end)
    end

    # Sabotage: pointed the process key at `Encryptor.Ecto.Tenant`'s - the
    # migrator corrupted the scope of a process that was also serving
    # something else, which ADR-0002 decision 3 forbids in so many words.
    test "the migrator's key is not the application's tenant scope" do
      :ok = Tenant.put("merchant_a19")

      RowTenant.with_tenant("merchant_7f3", fn ->
        assert {:ok, "merchant_a19"} = Tenant.get()
      end)

      assert {:ok, "merchant_a19"} = Tenant.get()
      :ok = Tenant.clear()
    end
  end
end
