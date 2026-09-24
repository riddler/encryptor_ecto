defmodule Encryptor.Ecto.ScalarTypesTest do
  @moduledoc """
  The six scalar wrappers ADR-0001 decision 1 left out of the founding set.

  One file rather than six, because the claim under test is that they are the
  same type six times over: `Encryptor.Ecto.Binary` with a cast arm and a parse
  arm, sharing one mechanism. A per-type file would assert the shared half six
  times and hide the one table worth reading, which is the round trip.
  """

  use ExUnit.Case, async: true

  import Encryptor.Ecto.ScopeSetup
  import Encryptor.Ecto.TestTelemetry, only: [capture_legacy_load: 1]

  alias Encryptor.Ecto.DecryptError
  alias Encryptor.Ecto.MissingScopeError
  alias Encryptor.Ecto.Scope
  alias Encryptor.Ecto.SerializationError
  alias Encryptor.Ecto.TestLegacy
  alias Encryptor.Ecto.TestSchemas.Reading
  alias Encryptor.Ecto.TestTypes
  alias Encryptor.Ecto.TestVaults

  doctest Encryptor.Ecto.Integer
  doctest Encryptor.Ecto.Float
  doctest Encryptor.Ecto.Date
  doctest Encryptor.Ecto.Time
  doctest Encryptor.Ecto.NaiveDateTime
  doctest Encryptor.Ecto.DateTime

  # Every scalar type, its declaration, the field it is declared on, and one
  # value of its own. The round trip is the same assertion for all six, so it
  # is written once and driven from here.
  @types [
    {TestTypes.RetryCount, :retry_count, 3},
    {TestTypes.FeeRate, :fee_rate, 0.0275},
    {TestTypes.DateOfBirth, :date_of_birth, ~D[1815-12-10]},
    {TestTypes.ContactWindowOpensAt, :contact_window_opens_at, ~T[09:30:00]},
    {TestTypes.AgreedAt, :agreed_at, ~N[2026-09-12 10:20:30]},
    {TestTypes.VerifiedAt, :verified_at, ~U[2026-09-12 10:20:30Z]}
  ]

  # The zero of each type: a value that is emphatically not `nil` and must
  # round-trip as itself (ADR-0001 decision 7).
  @zeroes [
    {TestTypes.RetryCount, :retry_count, 0},
    {TestTypes.FeeRate, :fee_rate, 0.0},
    {TestTypes.DateOfBirth, :date_of_birth, ~D[0001-01-01]},
    {TestTypes.ContactWindowOpensAt, :contact_window_opens_at, ~T[00:00:00]},
    {TestTypes.AgreedAt, :agreed_at, ~N[0001-01-01 00:00:00]},
    {TestTypes.VerifiedAt, :verified_at, ~U[0001-01-01 00:00:00Z]}
  ]

  # Every kind, the exact plaintext this package writes for its value from
  # `@types`, and the exact plaintext `cloak_ecto` writes for the same value.
  #
  # The cloak column is read from `cloak_ecto` 1.3.0, not from memory: every
  # scalar type there serializes with `to_string/1` - `lib/cloak_ecto/type.ex`
  # supplies it as the default `before_encrypt/1`, which `Integer` and `Float`
  # inherit, and `types/date.ex`, `types/time.ex`, `types/naive_date_time.ex`
  # and `types/date_time.ex` each re-state as `to_string(value)` after casting.
  # `to_string/1` is byte-identical to `to_iso8601/1` for `Date` and `Time`, so
  # four of the six agree byte for byte; for `NaiveDateTime` and `DateTime` it
  # is the *space*-separated form, so those two do not.
  @plaintexts [
    {TestTypes.RetryCount, :retry_count, 3, "3", "3"},
    {TestTypes.FeeRate, :fee_rate, 0.0275, "0.0275", "0.0275"},
    {TestTypes.DateOfBirth, :date_of_birth, ~D[1815-12-10], "1815-12-10", "1815-12-10"},
    {TestTypes.ContactWindowOpensAt, :contact_window_opens_at, ~T[09:30:00], "09:30:00",
     "09:30:00"},
    {TestTypes.AgreedAt, :agreed_at, ~N[2026-09-12 10:20:30], "2026-09-12T10:20:30",
     "2026-09-12 10:20:30"},
    {TestTypes.VerifiedAt, :verified_at, ~U[2026-09-12 10:20:30Z], "2026-09-12T10:20:30Z",
     "2026-09-12 10:20:30Z"}
  ]

  defp params(type, field), do: type.init(schema: Reading, field: field)

  describe "the option set is Binary's, and the messages name the macro" do
    # sabotage: host_quote/3's `impl` argument replaced by Binary, red - the
    # message would name Encryptor.Ecto.Binary rather than the macro written.
    test "an option outside the set raises naming the type the host wrote" do
      assert_raise ArgumentError,
                   ~r/unknown option \[:searchable\] for use Encryptor.Ecto.Date/,
                   fn ->
                     defmodule Searchable do
                       use Encryptor.Ecto.Date,
                         vault: Encryptor.Ecto.TestVaults.Merchant,
                         searchable: true
                     end
                   end
    end

    # sabotage: the same threading in missing_vault_message/2, red.
    test "a missing vault raises naming the type the host wrote" do
      assert_raise ArgumentError, ~r/use Encryptor.Ecto.Integer requires a :vault/, fn ->
        defmodule NoVault do
          use Encryptor.Ecto.Integer, scope: :none
        end
      end
    end

    # sabotage: validate_declaration!/2's `extra_options` argument, [] in every
    # scalar type, changed to [:json]. Red.
    test "refuses :json, which belongs to Map alone" do
      assert_raise ArgumentError, ~r/unknown option \[:json\]/, fn ->
        defmodule Serialized do
          use Encryptor.Ecto.Float,
            vault: Encryptor.Ecto.TestVaults.Merchant,
            json: Jason
        end
      end
    end
  end

  describe "cast is Ecto's own caster over the primitive" do
    # sabotage: Scalar.primitive/1's :integer clause -> :string, red.
    test "each type casts what a plain column of its primitive would" do
      assert TestTypes.RetryCount.cast("3", %{}) == {:ok, 3}
      assert TestTypes.FeeRate.cast(1, %{}) == {:ok, 1.0}
      assert TestTypes.DateOfBirth.cast("1815-12-10", %{}) == {:ok, ~D[1815-12-10]}
      assert TestTypes.ContactWindowOpensAt.cast("09:30:00", %{}) == {:ok, ~T[09:30:00]}

      assert TestTypes.AgreedAt.cast("2026-09-12T10:20:30", %{}) ==
               {:ok, ~N[2026-09-12 10:20:30]}

      assert TestTypes.VerifiedAt.cast("2026-09-12T10:20:30Z", %{}) ==
               {:ok, ~U[2026-09-12 10:20:30Z]}
    end

    # sabotage: Scalar.cast/2 returning {:ok, value} unconditionally, red.
    test "a value of the wrong shape is a validation failure, not an exception" do
      assert TestTypes.RetryCount.cast("4.2", %{}) == :error
      assert TestTypes.FeeRate.cast("four", %{}) == :error
      assert TestTypes.DateOfBirth.cast("12/09/2026", %{}) == :error
      assert TestTypes.ContactWindowOpensAt.cast(:noon, %{}) == :error
      assert TestTypes.AgreedAt.cast("2026-09-12", %{}) == :error
      assert TestTypes.VerifiedAt.cast("yesterday", %{}) == :error
    end

    # The cast is where sub-second precision goes, for the three types that
    # have any: it is Ecto's `:time`, `:naive_datetime` and `:utc_datetime`
    # doing it, before anything is encrypted. sabotage: primitive/1's
    # :utc_datetime clause -> :utc_datetime_usec, red.
    test "sub-second precision is truncated at the cast, not at the column" do
      assert TestTypes.ContactWindowOpensAt.cast(~T[09:30:00.500000], %{}) ==
               {:ok, ~T[09:30:00]}

      assert TestTypes.AgreedAt.cast(~N[2026-09-12 10:20:30.500000], %{}) ==
               {:ok, ~N[2026-09-12 10:20:30]}

      assert TestTypes.VerifiedAt.cast(~U[2026-09-12 10:20:30.500000Z], %{}) ==
               {:ok, ~U[2026-09-12 10:20:30Z]}
    end
  end

  describe "the round trip is Binary's, once per type" do
    setup_scope "merchant_7f3"

    # sabotage: Scalar.dump/5 handing the value to Binary without
    # to_plaintext/2, red - Binary refuses a non-binary by shape.
    test "every type stores ciphertext and reads its own value back" do
      for {type, field, value} <- @types do
        params = params(type, field)

        assert {:ok, ciphertext} = type.dump(value, nil, params)
        assert is_binary(ciphertext)
        assert type.load(ciphertext, nil, params) == {:ok, value}
      end
    end

    # sabotage: the generated type/1 delegating to something other than
    # Binary.type/1, red.
    test "the column is :binary for every one of them" do
      for {type, field, _value} <- @types do
        assert type.type(params(type, field)) == :binary
      end
    end

    # sabotage: Scalar.dump/5's nil clause deleted, red - nil then falls to
    # to_plaintext/2's catch-all and the dump raises instead of writing NULL.
    test "nil is NULL and the zero of the type is a value" do
      for {type, field, zero} <- @zeroes do
        params = params(type, field)

        assert type.dump(nil, nil, params) == {:ok, nil}
        assert type.load(nil, nil, params) == {:ok, nil}

        assert {:ok, ciphertext} = type.dump(zero, nil, params)
        assert byte_size(ciphertext) > 0
        assert type.load(ciphertext, nil, params) == {:ok, zero}
      end
    end

    # sabotage: the generated init/1 dropping the derived column, red.
    test "binds the same declared table and column Binary would" do
      params = params(TestTypes.DateOfBirth, :date_of_birth)
      assert %{table: "readings", column: "date_of_birth"} = params

      assert {:ok, ciphertext} = TestTypes.DateOfBirth.dump(~D[1815-12-10], nil, params)

      # The plaintext under the ciphertext is the ISO 8601 form, which is what
      # makes a column written by a legacy date type readable through this one
      # after the migrator re-encrypts it verbatim (ADR-0004, ADR-0002
      # decision 3).
      assert {:ok, "1815-12-10"} =
               TestVaults.Merchant.decrypt(ciphertext,
                 key: "merchant_7f3",
                 encryption_context: %{"table" => "readings", "column" => "date_of_birth"}
               )
    end

    # sabotage: the generated equal?/3 -> false, red.
    test "compares plaintext, and embeds as itself" do
      assert TestTypes.DateOfBirth.equal?(~D[1815-12-10], ~D[1815-12-10], %{})
      refute TestTypes.DateOfBirth.equal?(~D[1815-12-10], ~D[1815-12-11], %{})
      assert TestTypes.DateOfBirth.embed_as(:json, %{}) == :self
    end

    # sabotage: the generated load/3 returning the stored bytes unchanged, red.
    test "reports bytes that are not a well-formed message as an integrity event" do
      assert_raise DecryptError, fn ->
        TestTypes.RetryCount.load(<<0, 1, 2, 3>>, nil, params(TestTypes.RetryCount, :retry_count))
      end
    end
  end

  # The round trip above cannot see a drift that moved the encode and the
  # decode together: a type that wrote `13/12/1815` and read it back would
  # pass every assertion in it. These two tests are the ones that can, and
  # they are per kind because the two forms diverge per kind.
  describe "the plaintext bytes under the ciphertext" do
    setup_scope "merchant_7f3"

    # sabotage: Scalar.to_plaintext/2's :naive_datetime clause ->
    # `NaiveDateTime.to_string/1`, red here and green in the round trip.
    test "each kind writes exactly the bytes its documentation names" do
      for {type, field, value, plaintext, _cloak} <- @plaintexts do
        params = params(type, field)
        %{table: table, column: column} = params

        assert {:ok, ciphertext} = type.dump(value, nil, params)

        assert {:ok, ^plaintext} =
                 TestVaults.Merchant.decrypt(ciphertext,
                   key: "merchant_7f3",
                   encryption_context: %{"table" => table, "column" => column}
                 )
      end
    end

    # What makes a migrated column readable is the parse arm, not an agreement
    # about the written form: `Date.from_iso8601/1` and `Time.from_iso8601/1`
    # see the same bytes either way, and `NaiveDateTime.from_iso8601/1` and
    # `DateTime.from_iso8601/1` accept a space where this package writes a `T`.
    # The bytes here are written through `Binary` with the scalar's own params,
    # so the encryption context and the key are identical - the shape ADR-0002
    # decision 3's re-encrypt below the schema layer leaves in the column when
    # the legacy plaintext travelled as bytes.
    #
    # sabotage: Scalar.from_plaintext/2's :naive_datetime clause guarded to
    # refuse a plaintext whose separator is a space, red here and green
    # everywhere else in this file.
    test "each kind loads the plaintext cloak_ecto writes, re-encrypted verbatim" do
      for {type, field, value, _plaintext, cloak} <- @plaintexts do
        params = params(type, field)

        assert {:ok, ciphertext} = TestTypes.Pan.dump(cloak, nil, params)
        assert type.load(ciphertext, nil, params) == {:ok, value}
      end
    end
  end

  describe "a plaintext the parse arm cannot read" do
    setup_scope "merchant_7f3"

    # A decrypt that succeeded and a payload that is not a date: neither an
    # encryption failure nor an integrity event, which is the row ADR-0001
    # decision 6 gives SerializationError. sabotage: Scalar.parse!/4's :error
    # arm returning the plaintext, red.
    test "raises SerializationError naming the kind, on the decode side" do
      params = params(TestTypes.DateOfBirth, :date_of_birth)

      # Written through Binary with the same params, so the encryption context
      # is identical and only the type differs - the shape a column gets from a
      # migration onto the wrong scalar type.
      assert {:ok, ciphertext} = TestTypes.Pan.dump("the tenth of December", nil, params)

      error =
        assert_raise SerializationError, fn ->
          TestTypes.DateOfBirth.load(ciphertext, nil, params)
        end

      assert error.reason == {:unparsable, :date}
      assert error.direction == :decode
      assert error.serializer == Encryptor.Ecto.Date
    end

    # ADR-0001 decision 6: the parse failure is the point where a plaintext is
    # closest to hand. sabotage: detail/4's reason -> the payload itself, red.
    test "carries the table, the column and the kind, and never the payload" do
      params = params(TestTypes.RetryCount, :retry_count)
      assert {:ok, ciphertext} = TestTypes.Pan.dump("three attempts", nil, params)

      error =
        assert_raise SerializationError, fn ->
          TestTypes.RetryCount.load(ciphertext, nil, params)
        end

      message = Exception.message(error)

      assert message =~ "readings"
      assert message =~ "retry_count"
      assert message =~ "{:unparsable, :integer}"
      refute message =~ "three attempts"
      refute inspect(error) =~ "three attempts"
    end

    # A payload that parses and then has a tail is not a value of the type:
    # "3 attempts" is not the integer 3. sabotage: from_plaintext/2's `{value,
    # ""}` match -> `{value, _}`, red.
    test "refuses a payload the parser would otherwise read the front of" do
      params = params(TestTypes.RetryCount, :retry_count)
      assert {:ok, ciphertext} = TestTypes.Pan.dump("3 attempts", nil, params)

      assert_raise SerializationError, fn ->
        TestTypes.RetryCount.load(ciphertext, nil, params)
      end
    end
  end

  describe "a value that never passed cast" do
    setup_scope "merchant_7f3"

    # The `insert_all/3` shape: no changeset, so no cast. sabotage:
    # Scalar.dump/5's :error arm delegating to Binary anyway, red.
    test "is refused by shape, and its value is not reported" do
      params = params(TestTypes.DateOfBirth, :date_of_birth)

      error =
        assert_raise ArgumentError, fn ->
          TestTypes.DateOfBirth.dump("1815-12-10", nil, params)
        end

      message = Exception.message(error)

      assert message =~ "readings.date_of_birth"
      assert message =~ "expects a Date"
      assert message =~ "was given a binary"
      refute message =~ "1815-12-10"
    end

    # sabotage: to_plaintext/2's `time_zone: "Etc/UTC"` guard removed, red -
    # the zoned datetime would store its offset and read back shifted.
    test "a DateTime outside Etc/UTC is refused rather than silently shifted" do
      params = params(TestTypes.VerifiedAt, :verified_at)

      zoned = %Elixir.DateTime{
        ~U[2026-09-12 10:20:30Z]
        | time_zone: "Europe/Paris",
          zone_abbr: "CEST",
          utc_offset: 3600,
          std_offset: 3600
      }

      error =
        assert_raise ArgumentError, fn ->
          TestTypes.VerifiedAt.dump(zoned, nil, params)
        end

      assert Exception.message(error) =~ "expects a DateTime in Etc/UTC"
    end
  end

  describe "the scope rules are Binary's too" do
    # sabotage: the generated dump/3 delegating past Binary's scope
    # resolution, red.
    test "a dump with no scope set raises" do
      Scope.clear()

      assert_raise MissingScopeError, ~r/readings/, fn ->
        TestTypes.RetryCount.dump(3, nil, params(TestTypes.RetryCount, :retry_count))
      end
    end

    # sabotage: the generated init/1 not carrying `scope: :none` through, red.
    test "a field declared global asks no resolver anything" do
      Scope.clear()
      params = TestTypes.GlobalRetryCount.init(schema: Reading, field: :retry_count)

      assert {:ok, ciphertext} = TestTypes.GlobalRetryCount.dump(3, nil, params)
      assert TestTypes.GlobalRetryCount.load(ciphertext, nil, params) == {:ok, 3}
    end
  end

  # ADR-0004 decision 4's migration window, for a type whose legacy reader has
  # already parsed. These two live here rather than beside the rest of the
  # `:legacy` arms because what they hold is a claim about the *scalar*
  # wrappers, and the telemetry hook they share is scoped to the test that
  # attached it (`Encryptor.Ecto.TestTelemetry`), so an async neighbour's
  # `legacy_load` can no longer be read as one of theirs.
  describe "the migration window, for a type that parses" do
    setup :capture_legacy_load
    setup_scope "merchant_7f3"

    # A legacy date type has already parsed: it answers with a `Date`, not
    # with bytes. sabotage: Scalar.load/5's {:legacy, loaded} arm routed
    # through parse!/4, red - the parse then chokes on a struct.
    test "a scalar type returns the legacy reader's value without parsing it again" do
      params = params(TestTypes.DateOfBirthLegacy, :date_of_birth)
      bytes = TestLegacy.Format.encode("1815-12-10")

      assert TestTypes.DateOfBirthLegacy.load(bytes, nil, params) == {:ok, ~D[1815-12-10]}

      assert_received {:telemetry, [:encryptor_ecto, :legacy_load], _measurements, metadata}
      assert metadata == %{table: "readings", column: "date_of_birth"}
    end

    # The window is load-only (ADR-0004 decision 4). sabotage: the generated
    # dump/3 routed through the legacy module, red.
    test "a scalar type still writes, and reads its own writes, through the vault" do
      params = params(TestTypes.DateOfBirthLegacy, :date_of_birth)

      assert {:ok, ciphertext} = TestTypes.DateOfBirthLegacy.dump(~D[1815-12-10], nil, params)
      assert TestTypes.DateOfBirthLegacy.load(ciphertext, nil, params) == {:ok, ~D[1815-12-10]}

      refute_received {:telemetry, [:encryptor_ecto, :legacy_load], _measurements, _metadata}
    end
  end
end
