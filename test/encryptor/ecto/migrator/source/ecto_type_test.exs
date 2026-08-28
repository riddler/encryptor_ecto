defmodule Encryptor.Ecto.Migrator.Source.EctoTypeTest do
  use ExUnit.Case, async: true

  alias Encryptor.Ecto.Migrator.Source.EctoType
  alias Encryptor.Ecto.TestSources

  describe "adapting a plain Ecto.Type" do
    # Sabotage: the arity-1 clause called module.load(value, params) - every
    # cloak-shaped type became an UndefinedFunctionError.
    test "reads the bytes through the host's own load/1" do
      assert EctoType.load("legacy:cba", params(TestSources.LegacyType, 1)) == {:ok, "abc"}
    end

    # Sabotage: normalize(:error) returned {:ok, nil} - a failed decrypt was
    # re-encrypted as an empty value, permanently.
    test "an :error return becomes an error rather than a value" do
      assert EctoType.load("garbage", params(TestSources.LegacyType, 1)) ==
               {:error, :load_failed}
    end

    # Sabotage: dropped the {:error, reason} clause from normalize/1 - a
    # hand-rolled type's reason was reported as :invalid_source_result.
    test "an {:error, reason} return keeps its reason" do
      assert EctoType.load("garbage", params(TestSources.TupleErrorType, 1)) ==
               {:error, :wrong_key}
    end
  end

  describe "adapting an Ecto.ParameterizedType" do
    # Sabotage: the arity-3 clause called module.load(value) - a
    # ParameterizedType source became an UndefinedFunctionError on row one.
    test "reads the bytes through the host's own load/3" do
      params = params(TestSources.LegacyParameterizedType, 3)

      assert EctoType.load("legacy:cba", Map.put(params, :table, "cards")) == {:ok, "abc"}
    end

    # Sabotage: passed `params` instead of Map.drop(params, @adapter_keys) -
    # the adapter's own bookkeeping leaked into the host's type.
    test "the adapted module receives the migrator's params without the adapter's keys" do
      params = params(TestSources.LegacyParameterizedType, 3)
      migrator_params = %{table: "cards", column: "pan", tenant: "acct_A"}

      assert EctoType.load("legacy:cba", Map.merge(migrator_params, params)) == {:ok, "abc"}
      assert_received {:loaded_with, ^migrator_params, _loader?}
    end

    # Sabotage: passed nil as the loader - a composite or embedded legacy type
    # had nothing to resolve its inner type with.
    test "the adapted module receives an arity-2 loader" do
      assert EctoType.load("legacy:cba", params(TestSources.LegacyParameterizedType, 3)) ==
               {:ok, "abc"}

      assert_received {:loaded_with, _params, true}
    end

    # Sabotage: the same normalize(:error) -> {:ok, nil}, which reaches this
    # arm as well.
    test "an :error return becomes an error rather than a value" do
      assert EctoType.load("garbage", params(TestSources.LegacyParameterizedType, 3)) ==
               {:error, :load_failed}
    end
  end

  describe "converting a raise into data" do
    # Sabotage: the arity-1 clause's rescue reraised instead of converting -
    # one unreadable row halted a pass that should have classified it.
    test "a raise from the adapted module becomes an error" do
      assert EctoType.load("anything", params(TestSources.RaisingType, 1)) ==
               {:error, {:raised, TestSources.RaisingType.Failure}}
    end

    # Sabotage: the arity-3 clause's rescue reraised instead of converting -
    # the ParameterizedType arm halted a pass its arity-1 sibling survived.
    test "a raise from an adapted ParameterizedType becomes an error too" do
      assert EctoType.load("anything", params(TestSources.RaisingParameterizedType, 3)) ==
               {:error, {:raised, TestSources.RaisingType.Failure}}
    end

    # Sabotage: {:raised, exception.__struct__} changed to {:raised,
    # exception} - the foreign exception's value field reached the report.
    test "the reason carries the raising module's name and nothing it held" do
      assert {:error, reason} = EctoType.load("anything", params(TestSources.RaisingType, 1))

      refute inspect(reason) =~ "4111111111111111"
      refute inspect(reason) =~ "boom"
    end

    # Sabotage: added `catch thrown -> {:error, {:thrown, thrown}}` to the
    # arity-1 clause - misbehaviour was given a classification and a reason
    # carrying whatever was thrown.
    test "a throw is not caught: it is misbehaviour, not a failed decrypt" do
      assert catch_throw(EctoType.load("anything", params(TestSources.ThrowingType, 1))) == :no
    end
  end

  describe "an unexpected result shape" do
    # Sabotage: replaced normalize/1's catch-all with no clause - the
    # unmatched plaintext landed in a FunctionClauseError.
    test "is an error that carries no value" do
      assert {:error, reason} = EctoType.load("anything", params(TestSources.MisbehavingType, 1))

      assert reason == :invalid_source_result
      refute inspect(reason) =~ "4111111111111111"
    end
  end

  defp params(module, arity), do: %{source_module: module, source_arity: arity}
end
