defmodule Encryptor.Ecto.MigratorTest do
  @moduledoc """
  What the engine refuses before it visits a row.

  Every refusal here happens with no database in reach, which is the point:
  ADR-0002 decision 7's required mode, proposed amendment 4's primary-key
  restriction and decision 11's tenant filter are all decided from the plan
  and the options, and discovering any of them on row one of a live pass is
  the failure the checks exist to remove.
  """

  use ExUnit.Case, async: true

  alias Encryptor.Ecto.Migrator
  alias Encryptor.Ecto.TestEnginePlans
  alias Encryptor.Ecto.TestSchemas

  describe "run/2 option checks" do
    # Sabotage: made `mode!/1`'s `:error` arm return `:dry_run` - a run with no
    # mode silently rehearsed instead of refusing, which is the default
    # decision 7 exists to forbid.
    test "a missing mode is refused, and the message says why there is no default" do
      error =
        assert_raise ArgumentError, fn ->
          Migrator.run(TestEnginePlans.Cards, [])
        end

      message = error.message
      assert message =~ "requires `mode:`"
      assert message =~ ":dry_run"
      assert message =~ ":write"
    end

    # Sabotage: widened the guard to `mode in [:dry_run, :write, :migrate]` -
    # a misspelled mode was accepted and would have run as neither.
    test "a mode outside the two is refused" do
      assert_raise ArgumentError, ~r/mode: expects :dry_run or :write/, fn ->
        Migrator.run(TestEnginePlans.Cards, mode: :migrate)
      end
    end

    # Sabotage: dropped `unknown!/1`'s raise - a typo'd `batch_sze:` was
    # accepted and silently ran with the default batch size.
    test "an unknown option is refused and the known set is named" do
      error =
        assert_raise ArgumentError, fn ->
          Migrator.run(TestEnginePlans.Cards, mode: :dry_run, batch_sze: 10)
        end

      message = error.message
      assert message =~ "unknown options [:batch_sze]"
      assert message =~ ":checkpoint_table"
    end

    # Sabotage: removed the `checkpoint: :none` + `resume: true` check - the
    # run started and resumed from a checkpoint that is never written.
    test "resuming with no checkpoint is refused" do
      assert_raise ArgumentError, ~r/never written is a request with no/, fn ->
        Migrator.run(TestEnginePlans.Cards, mode: :write, checkpoint: :none, resume: true)
      end
    end

    # Sabotage: made `batch_size!/1` accept 0 - the keyset query asked for no
    # rows and the pass "finished" without visiting anything.
    test "a non-positive batch size is refused" do
      assert_raise ArgumentError, ~r/batch_size: expects a positive integer/, fn ->
        Migrator.run(TestEnginePlans.Cards, mode: :dry_run, batch_size: 0)
      end
    end

    # Sabotage: made `progress!/1` accept any term - a non-function progress
    # option raised inside the first batch instead, mid-transaction.
    test "a progress option that is not a one-argument function is refused" do
      assert_raise ArgumentError, ~r/progress: expects a one-argument function/, fn ->
        Migrator.run(TestEnginePlans.Cards, mode: :dry_run, progress: :please)
      end
    end

    # Sabotage: dropped `assert_only!/1`'s shape check - a malformed `only:`
    # matched nothing and the run reported a green pass over zero fields.
    test "a malformed only: is refused" do
      assert_raise ArgumentError, ~r/only: expects a list of/, fn ->
        Migrator.run(TestEnginePlans.Cards, mode: :dry_run, only: [TestSchemas.Card])
      end
    end
  end

  describe "run/2 plan checks" do
    # Sabotage: dropped the `function_exported?(plan_module, :__plan__, 0)`
    # half - a schema module was accepted as a plan and failed with an
    # UndefinedFunctionError instead of a message naming the DSL.
    test "a module that is not a plan is refused" do
      assert_raise ArgumentError, ~r/expects a plan module/, fn ->
        Migrator.run(TestSchemas.Card, mode: :dry_run)
      end
    end

    # Sabotage: made `key!/1` fall through to `{:id, :integer}` for the error
    # arm - a composite-key schema was paged over one column of its key,
    # which is the silent skip amendment 4 refuses.
    test "a composite primary key is refused, naming the schema and the key" do
      error =
        assert_raise ArgumentError, fn ->
          Migrator.run(TestEnginePlans.Composite, mode: :dry_run)
        end

      message = error.message
      assert message =~ "Composite"
      assert message =~ "[:merchant_id, :sequence]"
      assert message =~ "the founding implementation does not support"
    end

    # Sabotage: dropped `tenant_column!/2`'s raise - a tenant filter against a
    # `tenant :none` rewrite visited every row while the operator believed the
    # run was scoped to one tenant.
    test "a tenant filter against a rewrite with no tenant column is refused" do
      error =
        assert_raise ArgumentError, fn ->
          Migrator.run(TestEnginePlans.Global, mode: :dry_run, only_tenants: ["merchant_7f3"])
        end

      message = error.message
      assert message =~ "Signup"
      assert message =~ "only_tenants:"
    end
  end
end
