defmodule Encryptor.Ecto.Migrator.RowScopeTest do
  @moduledoc """
  The resolver the migrator installs for a `scope_from` rewrite.

  The interesting cases are all about what happens *between* rows: a scope
  that is restored after a raise, and an absent or empty scope that is an
  error rather than the `:none` that would re-encrypt the row under the wrong
  key.
  """

  use ExUnit.Case, async: true

  alias Encryptor.Ecto.Migrator.RowScope
  alias Encryptor.Ecto.Scope

  describe "resolve/2" do
    # Sabotage: made the absent arm answer `:none` - a row visited with no
    # scope installed was encrypted under the vault's single key instead of
    # failing, which is the permanent wrong-key write the arm exists to
    # prevent.
    test "an absent scope is an error naming the operation" do
      assert {:error, {:no_row_scope, :dump}} = RowScope.resolve(:dump, %{})
    end

    # Sabotage: made the `nil` arm answer `:none` - a row whose scope column
    # was NULL migrated silently under the wrong key.
    test "a NULL scope column is an error, not :none" do
      RowScope.with_scope(nil, fn ->
        assert {:error, {:null_scope_column, :load}} = RowScope.resolve(:load, %{})
      end)
    end

    # Sabotage: dropped the `scope != ""` guard - an empty scope column
    # resolved to `""` and the vault was asked for a key nobody named.
    test "an empty scope column is an error" do
      RowScope.with_scope("", fn ->
        assert {:error, {:unusable_scope_column, :dump}} = RowScope.resolve(:dump, %{})
      end)
    end

    # Sabotage: made the catch-all render the value - a scope selector from a
    # column this package did not choose reached a failure report.
    test "a scope of another shape is reported by shape only" do
      RowScope.with_scope(42, fn ->
        assert {:error, reason} = RowScope.resolve(:dump, %{})
        refute inspect(reason) =~ "42"
      end)
    end
  end

  describe "with_scope/2" do
    # Sabotage: dropped the `after` - a type raising on one row left that
    # row's scope installed for the next one, which is a wrong-key encrypt
    # produced by an error path.
    test "restores the previous value even when the function raises" do
      assert_raise RuntimeError, fn ->
        RowScope.with_scope("merchant_7f3", fn -> raise "boom" end)
      end

      assert {:error, {:no_row_scope, :dump}} = RowScope.resolve(:dump, %{})
    end

    # Sabotage: read the previous value with `Process.put/2`'s return instead
    # of a `get` - an outer row's scope was deleted rather than restored on
    # the way out of a nested call.
    test "nested calls restore the outer row's scope" do
      RowScope.with_scope("merchant_7f3", fn ->
        RowScope.with_scope("merchant_a19", fn ->
          assert {:ok, "merchant_a19"} = RowScope.resolve(:dump, %{})
        end)

        assert {:ok, "merchant_7f3"} = RowScope.resolve(:dump, %{})
      end)
    end

    # Sabotage: pointed the process key at `Encryptor.Ecto.Scope`'s - the
    # migrator corrupted the scope of a process that was also serving
    # something else, which ADR-0002 decision 3 forbids in so many words.
    test "the migrator's key is not the application's process scope" do
      :ok = Scope.put("merchant_a19")

      RowScope.with_scope("merchant_7f3", fn ->
        assert {:ok, "merchant_a19"} = Scope.get()
      end)

      assert {:ok, "merchant_a19"} = Scope.get()
      :ok = Scope.clear()
    end
  end
end
