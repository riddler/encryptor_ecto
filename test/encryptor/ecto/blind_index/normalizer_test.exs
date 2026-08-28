defmodule Encryptor.Ecto.BlindIndex.NormalizerTest do
  use ExUnit.Case, async: true

  alias Encryptor.Ecto.BlindIndex.NormalizationError
  alias Encryptor.Ecto.BlindIndex.Normalizer
  alias Encryptor.Ecto.TestNormalizers

  doctest Encryptor.Ecto.BlindIndex.Normalizer

  # The context a failure is allowed to name. Nothing here is a value.
  @context [table: "signups", column: "email", index_name: "email_index"]

  describe "the built-in set" do
    # sabotage: normalize!/3's :none arm -> String.trim(value), red.
    test ":none is byte-exact, including the bytes a host might expect trimmed" do
      assert Normalizer.normalize!(:none, " Bob@Example.COM ") == " Bob@Example.COM "
      assert Normalizer.normalize!(:none, "") == ""
    end

    # sabotage: normalize!/3's :trim arm -> value, red.
    test ":trim removes surrounding whitespace and changes nothing else" do
      assert Normalizer.normalize!(:trim, "  Bob@Example.COM \n") == "Bob@Example.COM"
    end

    # sabotage: normalize!/3's :downcase arm -> String.downcase(value), red.
    test ":downcase trims first, so a padded value and a bare one agree" do
      assert Normalizer.normalize!(:downcase, " Bob@Example.COM ") ==
               Normalizer.normalize!(:downcase, "bob@example.com")
    end

    # sabotage: normalize!/3's :email arm -> value, red. :email is exactly :downcase, and
    # the two names exist so a schema line can say which decision it is making.
    test ":email is exactly :downcase" do
      for value <- [" Bob@Example.COM ", "", "ALREADY@lower.test"] do
        assert Normalizer.normalize!(:email, value) ==
                 Normalizer.normalize!(:downcase, value)
      end
    end

    # sabotage: digits/1's `byte in ?0..?9` -> `byte in ?1..?9`, red.
    test ":digits keeps digits and drops everything else" do
      assert Normalizer.normalize!(:digits, "+1 (555) 0100-x") == "15550100"
      assert Normalizer.normalize!(:digits, "no digits here") == ""
    end

    # ADR-0003 Q5, asserted rather than only documented: `:digits` merges an
    # international number with a local one, which under decision 9's unique
    # constraint merges two rows. The test exists so that resolving Q5 the
    # other way has to delete an assertion rather than only a paragraph.
    #
    # sabotage: normalize!/3's :digits arm -> value, red.
    test ":digits merges +1 555 0100 with 5550100, which Q5 flags" do
      assert Normalizer.normalize!(:digits, "+1 555 0100") == "15550100"
      assert Normalizer.normalize!(:digits, "5550100") == "5550100"
      refute Normalizer.normalize!(:digits, "+1 555 0100") == "5550100"
    end
  end

  describe "totality" do
    # ADR-0003 decision 4 requires the normalizers to be total on any binary.
    # A `:binary` column holds bytes, not text, so the invalid-UTF-8 case is
    # reachable from a host that stored one.
    #
    # sabotage: the :none arm wrapped in a String.valid?/1 guard that raises
    # otherwise, red.
    test "every built-in normalizer answers on a binary that is not valid UTF-8" do
      invalid = <<0xFF, ?A, 0x20, ?7>>

      refute String.valid?(invalid)

      for normalizer <- Normalizer.builtin() do
        assert is_binary(Normalizer.normalize!(normalizer, invalid))
      end
    end

    # sabotage: the :trim arm -> `" " <> value`, red. A normalizer that is not
    # idempotent makes a reindex change values it was supposed to preserve.
    test "every built-in normalizer is idempotent" do
      for normalizer <- Normalizer.builtin(),
          value <- [" Bob@Example.COM ", "+1 (555) 0100", "", <<0xFF, ?A>>] do
        once = Normalizer.normalize!(normalizer, value)

        assert Normalizer.normalize!(normalizer, once) == once
      end
    end
  end

  describe "a host normalizer" do
    # sabotage: normalize!/3's `{module, function}` arm -> `host(...) <> "x"`, red.
    test "is used when it answers with a binary" do
      assert Normalizer.normalize!({TestNormalizers, :e164}, "+1 (555) 0100") == "+15550100"
    end

    # sabotage: call/3's rescue arm -> reraise, red - the ArgumentError escapes
    # as itself, carrying the plaintext in its message.
    test "raising becomes a NormalizationError naming the exception and no value" do
      error =
        assert_raise NormalizationError, fn ->
          Normalizer.normalize!({TestNormalizers, :raising}, "4111111111111111", @context)
        end

      assert error.reason == {:raised, ArgumentError}
      assert error.normalizer == {TestNormalizers, :raising}
      assert error.table == "signups"
      assert error.column == "email"
      assert error.index_name == "email_index"
    end

    # sabotage: call/3's `:throw` catch arm -> `{:ok, thrown}`, red.
    test "throwing becomes a NormalizationError" do
      error =
        assert_raise NormalizationError, fn ->
          Normalizer.normalize!({TestNormalizers, :throwing}, "4111111111111111", @context)
        end

      assert error.reason == {:threw, :a_value}
    end

    # sabotage: call/3's `:exit` catch arm -> `{:ok, reason}`, red.
    test "exiting becomes a NormalizationError" do
      error =
        assert_raise NormalizationError, fn ->
          Normalizer.normalize!({TestNormalizers, :exiting}, "4111111111111111", @context)
        end

      assert error.reason == {:exited, :for_a_reason}
    end

    # sabotage: host/5's `{:ok, _not_a_binary}` arm -> `to_string(other)`, red.
    # The HMAC would otherwise be computed over a charlist and crash one layer
    # down, naming :crypto rather than the declaration.
    test "returning a non-binary becomes a NormalizationError" do
      error =
        assert_raise NormalizationError, fn ->
          Normalizer.normalize!({TestNormalizers, :charlist}, "4111", @context)
        end

      assert error.reason == {:returned, :not_a_binary}
    end

    # sabotage: call/3's rescue arm -> reraise, red. A misspelled function is
    # the likeliest of these failures and the one a host meets first.
    test "not being exported becomes a NormalizationError" do
      error =
        assert_raise NormalizationError, fn ->
          Normalizer.normalize!({TestNormalizers, :no_such_function}, "4111", @context)
        end

      assert error.reason == {:raised, UndefinedFunctionError}
    end
  end

  describe "what a failure may not carry" do
    # The prohibition of ADR-0001 decision 6, extended by ADR-0003 to index
    # values. `TestNormalizers.raising/1` puts the plaintext in its message on
    # purpose: that message is the nearest thing to hand at the moment of
    # failure and copying it is the mistake this test exists to fail.
    #
    # sabotage: call/3's rescue arm -> {:error, {:raised, Exception.message(exception)}},
    # red - the reason stops being a name and becomes the host's message, which
    # is where the plaintext would ride in.
    test "no rendering of a NormalizationError carries the plaintext" do
      pan = "4111111111111111"

      error =
        assert_raise NormalizationError, fn ->
          Normalizer.normalize!({TestNormalizers, :raising}, pan, @context)
        end

      assert {:raised, module} = error.reason
      assert is_atom(module)
      refute Exception.message(error) =~ pan
      refute inspect(error) =~ pan
      refute Exception.format(:error, error, []) =~ pan
    end

    # sabotage: the non-binary clause of normalize!/3 -> `inspect(value)`, red.
    test "a value that is not a binary is refused rather than passed through" do
      error =
        assert_raise NormalizationError, fn ->
          Normalizer.normalize!(:none, :not_a_binary, @context)
        end

      assert error.reason == {:invalid, :value, :not_a_binary}
    end

    # sabotage: normalize!/3's `other` arm -> value, red. An unknown normalizer
    # reaching a computation would fingerprint the raw plaintext under a
    # declaration that says it does not.
    test "an unknown normalizer is refused rather than treated as :none" do
      error =
        assert_raise NormalizationError, fn ->
          Normalizer.normalize!(:uppercase, "bob", @context)
        end

      assert error.reason == {:invalid, :normalize, :unknown_normalizer}
    end
  end

  describe "valid?/1" do
    # sabotage: valid?/1's `named?(module) and named?(function)` -> true, red.
    # `{nil, nil}` is a pair of atoms and would otherwise pass a declaration.
    test "refuses a pair whose halves are not names" do
      refute Normalizer.valid?({nil, nil})
      refute Normalizer.valid?({MyApp.Phone, true})
      assert Normalizer.valid?({MyApp.Phone, :e164})
    end
  end
end
