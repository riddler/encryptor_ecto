defmodule Encryptor.Ecto.ScopeSetupTest do
  use ExUnit.Case, async: true

  import Encryptor.Ecto.ScopeSetup, only: [setup_scope: 1]

  alias Encryptor.Ecto.Scope
  alias Encryptor.Ecto.ScopeSetup

  doctest Encryptor.Ecto.ScopeSetup

  describe "setup_scope/1 inside a describe block" do
    setup_scope "merchant_7f3"

    # sabotage: made the macro expand to `setup_all` -> red, because a
    # setup_all callback runs in a different process from the test.
    test "sets the named scope for each test in the block" do
      assert {:ok, "merchant_7f3"} = Scope.get()
    end

    # sabotage: stored the scope in :persistent_term rather than the process
    # dictionary -> red, because the scope would then propagate.
    test "scopes the test process only; work the test spawns does not inherit it" do
      task = Task.async(&Scope.get/0)

      assert :error = Task.await(task)
    end

    # sabotage: made wrap/2 clear rather than restore -> red.
    test "wrap/2 nests inside the scoped scope and restores it" do
      assert "merchant_a19" = Scope.wrap("merchant_a19", &Scope.fetch!/0)
      assert {:ok, "merchant_7f3"} = Scope.get()
    end
  end

  describe "a describe block with no setup_scope call" do
    # sabotage: stored the scope in :persistent_term rather than the process
    # dictionary -> red, because the block above would leak its scope here.
    test "has no scope set, and the helper installs no default" do
      assert :error = Scope.get()
    end
  end

  describe "put_scope/1" do
    # sabotage: made put_scope/1 return the previous scope -> red.
    test "returns :ok and sets the scope" do
      assert :ok = ScopeSetup.put_scope("merchant_7f3")
      assert {:ok, "merchant_7f3"} = Scope.get()
    end

    # sabotage: made the fallback install a default scope rather than raise
    # -> red, which is the whole failure this helper is not allowed to have.
    test "refuses a non-binary scope, saying it substitutes no default" do
      error = assert_raise ArgumentError, fn -> ScopeSetup.put_scope(:merchant_7f3) end

      assert error.message =~ "expected a non-empty scope identifier"
      assert error.message =~ "never substitutes a default scope"
    end

    # sabotage: relaxed the guard to plain is_binary/1 -> red.
    test "refuses an empty scope identifier" do
      assert_raise ArgumentError, fn -> ScopeSetup.put_scope("") end
    end

    # sabotage: made put_scope/1 return :error for a valid scope -> red,
    # because ExUnit rejects the setup return value.
    test "is usable directly as an ExUnit setup callback" do
      assert :ok = ScopeSetup.put_scope("merchant_7f3")
    end
  end
end

defmodule Encryptor.Ecto.ScopeSetupCaseTest do
  use ExUnit.Case, async: true

  import Encryptor.Ecto.ScopeSetup, only: [setup_scope: 1]

  alias Encryptor.Ecto.Scope

  setup_scope "merchant_7f3"

  # sabotage: made the macro expand to `setup_all` -> red, for the same reason
  # as the describe-scoped case: the scope would be in the wrong process.
  test "a case-level call scopes every test in the case" do
    assert {:ok, "merchant_7f3"} = Scope.get()
  end

  # sabotage: had put_scope/1 write to :persistent_term -> red, because the
  # spawned task would then see a scope it was never handed.
  test "and does not leak the scope out of the test process" do
    assert {:ok, "merchant_7f3"} = Scope.get()
    assert :error = Task.await(Task.async(&Scope.get/0))
  end
end
