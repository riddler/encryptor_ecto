defmodule Encryptor.Ecto.Migrator.SourceTest do
  use ExUnit.Case, async: true

  alias Encryptor.Ecto.Migrator.Source
  alias Encryptor.Ecto.TestSources

  doctest Encryptor.Ecto.Migrator.Source

  describe "resolve!/2" do
    # Sabotage: replaced the cond's `source?(module) ->` guard with `false ->`
    # - a direct source fell through to the adapter arms and was refused.
    test "a module implementing the behaviour is used as-is" do
      assert Source.resolve!(TestSources.DirectSource, schema: Card, field: :pan) ==
               {TestSources.DirectSource, %{}}
    end

    # Sabotage: the same `false ->` - this is the case that distinguishes the
    # behaviour check from the exported-load probe below it.
    test "the behaviour wins over an exported load/1 on the same module" do
      assert {TestSources.DirectSourceAlsoEctoType, %{}} =
               Source.resolve!(TestSources.DirectSourceAlsoEctoType, [])
    end

    # Sabotage: `source_arity: 3` changed to 1 - an Ecto.Type resolved as a
    # ParameterizedType.
    test "an Ecto.ParameterizedType resolves to the adapter at arity 3" do
      assert Source.resolve!(TestSources.LegacyParameterizedType, field: :pan) ==
               {Source.EctoType,
                %{source_module: TestSources.LegacyParameterizedType, source_arity: 3}}
    end

    # Sabotage: `function_exported?(module, :load, 1)` changed to arity 2 - a
    # plain Ecto.Type fell through to the CompileError.
    test "a plain Ecto.Type resolves to the adapter at arity 1" do
      assert Source.resolve!(TestSources.LegacyType, field: :pan) ==
               {Source.EctoType, %{source_module: TestSources.LegacyType, source_arity: 1}}
    end

    # Sabotage: dropped the final `true ->` arm's raise for `{module, %{}}` -
    # a module that reads nothing was accepted and would fail on row one.
    test "a module that reads nothing raises CompileError naming the field" do
      error =
        assert_raise CompileError, fn ->
          Source.resolve!(TestSources.NotASource, schema: Card, field: :pan)
        end

      message = Exception.message(error)

      assert message =~ "Card.pan"
      assert message =~ "load/1"
      assert message =~ "load/3"
    end

    # Sabotage: dropped the `Code.ensure_loaded?` arm - the missing module
    # raised UndefinedFunctionError from module_info/1 instead.
    test "a module that cannot be loaded raises CompileError naming the field" do
      error =
        assert_raise CompileError, fn ->
          Source.resolve!(No.Such.Module, schema: Card, field: :pan)
        end

      message = Exception.message(error)

      assert message =~ "Card.pan"
      assert message =~ "could not be loaded"
    end

    # Sabotage: hard-coded file/line instead of reading field_opts - the
    # CompileError pointed at nofile:0 for a real plan.
    test "the CompileError carries the caller's file and line" do
      error =
        assert_raise CompileError, fn ->
          Source.resolve!(TestSources.NotASource,
            schema: Card,
            field: :pan,
            file: "lib/plan.ex",
            line: 12
          )
        end

      assert error.file == "lib/plan.ex"
      assert error.line == 12
    end

    # Sabotage: `describe/1`'s fully-identified arm rendered "a plan field" -
    # the four shapes collapsed into the anonymous one.
    test "the message degrades gracefully as identifying options fall away" do
      for {opts, expected} <- [
            {[], "a plan field"},
            {[field: :pan], "the plan field :pan"},
            {[schema: Card], "a plan field of Card"},
            {[schema: Card, field: :pan], "Card.pan"}
          ] do
        error =
          assert_raise(CompileError, fn -> Source.resolve!(TestSources.NotASource, opts) end)

        assert Exception.message(error) =~ expected
      end
    end
  end

  describe "load/3" do
    # Sabotage: `Map.merge(params, source_params)` reversed - the adapter keys
    # lost to a field key of the same name.
    test "merges the resolution's params over the migrator's" do
      resolved = Source.resolve!(TestSources.LegacyType, [])

      assert Source.load(resolved, "legacy:cba", %{source_arity: 3, table: "cards"}) ==
               {:ok, "abc"}
    end

    # Sabotage: passed only the resolution's params to source.load/2 - a direct
    # source stopped receiving the per-row context.
    test "hands a direct source the migrator's params" do
      resolved = Source.resolve!(TestSources.DirectSource, [])
      params = %{table: "cards", column: "pan", tenant: "acct_A"}

      assert Source.load(resolved, "direct:cba", params) == {:ok, "abc"}
      assert_received {:direct_params, ^params}
    end

    # Sabotage: `{:error, reason}` arm rewritten to `{:error, :load_failed}` -
    # a direct source's own reason was discarded.
    test "passes a direct source's error reason through unchanged" do
      resolved = Source.resolve!(TestSources.DirectSource, [])

      assert Source.load(resolved, "other", %{}) == {:error, :unreadable}
    end

    # Sabotage: removed the `_other` catch-all from the case - the unmatched
    # plaintext landed in a CaseClauseError message.
    test "an unexpected result shape from a direct source is an error" do
      resolved = Source.resolve!(TestSources.MisbehavingSource, [])

      assert Source.load(resolved, "anything", %{}) == {:error, :invalid_source_result}
    end

    # Sabotage: removed the `unwrap/1` call from the {:ok, loaded} arm - the
    # migrator would have re-encrypted the closure rather than the value.
    test "invokes a zero-arity result and takes its value as the plaintext" do
      resolved = Source.resolve!(TestSources.ClosureType, [])

      assert Source.load(resolved, "deferred:cba", %{}) == {:ok, "abc"}
    end
  end

  describe "unwrap/1" do
    # Sabotage: `is_function(value, 0)` changed to `is_function(value)` - a
    # non-zero-arity term was called and blew up.
    test "leaves a value that is not a zero-arity function alone" do
      fun = fn x -> x end

      assert Source.unwrap("abc") == {:ok, "abc"}
      assert Source.unwrap(nil) == {:ok, nil}
      assert Source.unwrap(fun) == {:ok, fun}
    end

    # Sabotage: made unwrap/1 recurse on its own result - "invoked once"
    # became "invoked until it stops being a function".
    test "invokes once, so a closure returning a closure yields that closure" do
      assert {:ok, inner} = Source.unwrap(fn -> fn -> "abc" end end)
      assert is_function(inner, 0)
    end

    # Sabotage: the rescue reraised instead of converting - a deferred decrypt
    # that raised halted the pass where an eager one would have been classified.
    test "a raising closure becomes an error naming only the raising module" do
      assert Source.unwrap(fn -> raise TestSources.RaisingType.Failure, message: "boom" end) ==
               {:error, {:raised, TestSources.RaisingType.Failure}}
    end
  end

  describe "the redaction rule" do
    # Sabotage: `{:raised, exception.__struct__}` changed to `{:raised,
    # exception}` - the exception's own value reached the reason.
    test "no reason from a raising closure carries the value it was holding" do
      pan = "4111111111111111"

      assert {:error, reason} =
               Source.unwrap(fn ->
                 raise TestSources.RaisingType.Failure, message: "boom", value: pan
               end)

      refute inspect(reason) =~ pan
    end

    # Sabotage: the `_other` catch-all rewritten to `other -> {:error, other}`
    # - the misbehaving source's plaintext became the reason.
    test "no reason from an unexpected result shape carries the result" do
      resolved = Source.resolve!(TestSources.MisbehavingSource, [])

      assert {:error, reason} = Source.load(resolved, "anything", %{})
      refute inspect(reason) =~ "4111111111111111"
    end
  end
end
