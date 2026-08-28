defmodule Encryptor.Ecto.MapTest do
  use ExUnit.Case, async: true

  import Encryptor.Ecto.TenantScope

  alias Encryptor.Ecto.DecryptError
  alias Encryptor.Ecto.MissingTenantError
  alias Encryptor.Ecto.SerializationError
  alias Encryptor.Ecto.Tenant
  alias Encryptor.Ecto.TestSchemas.Card
  alias Encryptor.Ecto.TestSerializers
  alias Encryptor.Ecto.TestTypes
  alias Encryptor.Ecto.TestVaults

  doctest Encryptor.Ecto.Map

  # The plaintext every test in this file encrypts: authorization metadata a
  # card processor would rather not leave readable in the database.
  @metadata %{"channel" => "web", "avs_result" => "Y"}

  defp params(type, field \\ :metadata), do: type.init(schema: Card, field: field)

  describe "the option set" do
    # sabotage: validate_declaration!/4's extra_options argument, passed as
    # [:json] at map.ex's /2 wrapper, changed to []. Red, and red at compile:
    # TestTypes.Sorted's own declaration stops compiling, which is the point -
    # the refusal fires while the host compiles.
    test "accepts :json, which Binary does not" do
      assert %{json: TestSerializers.Sorted} = params(TestTypes.Sorted)
    end

    # sabotage: the declared_by threading in unknown_options_message/4, red.
    test "names the macro the host actually wrote, and keeps the set closed" do
      assert_raise ArgumentError,
                   ~r/unknown option \[:searchable\] for use Encryptor.Ecto.Map/,
                   fn ->
                     defmodule Searchable do
                       use Encryptor.Ecto.Map,
                         vault: Encryptor.Ecto.TestVaults.Merchant,
                         searchable: true
                     end
                   end
    end

    # sabotage: validated_serializer!/2's default -> nil, red.
    test "defaults the serializer to Jason" do
      assert %{json: Jason} = params(TestTypes.Metadata)
    end

    # sabotage: the function_exported? branch of validated_serializer!/2
    # deleted, red - the declaration would be accepted and the first load
    # would fail instead.
    test "refuses a serializer missing half the contract" do
      assert_raise ArgumentError, ~r/does not export both encode!\/1 and decode!\/1/, fn ->
        Encryptor.Ecto.Map.init(
          [vault: TestVaults.Merchant, json: TestSerializers.Halfway],
          schema: Card,
          field: :metadata
        )
      end
    end

    # sabotage: serializer_message/3's subject -> the literal "an encrypted
    # field", red. Found by the sabotage pass: nothing else in this file
    # asserted the message names the field, so the refusal could have been
    # unattributable and every test still passed.
    test "names the field the serializer was declared on" do
      error =
        assert_raise ArgumentError, fn ->
          Encryptor.Ecto.Map.init(
            [vault: TestVaults.Merchant, json: TestSerializers.Halfway],
            schema: Card,
            field: :metadata
          )
        end

      assert error.message =~ "cards.metadata"
    end

    # sabotage: the Code.ensure_loaded? branch deleted, red - a module that
    # does not exist would be reported as missing its exports instead.
    test "refuses a serializer module that cannot be loaded" do
      assert_raise ArgumentError, ~r/could not be loaded/, fn ->
        Encryptor.Ecto.Map.init(
          [vault: TestVaults.Merchant, json: NoSuchSerializer],
          schema: Card,
          field: :metadata
        )
      end
    end

    # sabotage: validated_serializer!/2's is_atom guard dropped, red.
    test "refuses a :json that is not a module at all" do
      assert_raise ArgumentError, ~r/is not a module/, fn ->
        Encryptor.Ecto.Map.init(
          [vault: TestVaults.Merchant, json: "Jason"],
          schema: Card,
          field: :metadata
        )
      end
    end

    # sabotage: init/2 not delegating to Binary.init/2, red.
    test "carries Binary's whole option set through" do
      assert %{table: "cards", column: "metadata", tenant: :scope, context: %{}} =
               params(TestTypes.Metadata)

      assert_raise ArgumentError, ~r/the :legacy type .* could not be loaded/, fn ->
        Encryptor.Ecto.Map.init(
          [vault: TestVaults.Merchant, legacy: SomeOldType],
          schema: Card,
          field: :metadata
        )
      end
    end
  end

  describe "cast" do
    # sabotage: cast/2's map arm -> :error, red.
    test "accepts a plain map, including the empty one" do
      assert Encryptor.Ecto.Map.cast(@metadata, %{}) == {:ok, @metadata}
      assert Encryptor.Ecto.Map.cast(%{}, %{}) == {:ok, %{}}
      assert Encryptor.Ecto.Map.cast(nil, %{}) == {:ok, nil}
    end

    # sabotage: cast/2's catch-all -> {:ok, nil}, red.
    test "refuses a non-map, which is a validation failure" do
      assert Encryptor.Ecto.Map.cast("channel=web", %{}) == :error
      assert Encryptor.Ecto.Map.cast([{"channel", "web"}], %{}) == :error
      assert Encryptor.Ecto.Map.cast(:web, %{}) == :error
    end

    # A struct could not round-trip: decision 8 fixes the loaded value as a
    # plain string-keyed map. sabotage: the `not is_struct(value)` guard
    # dropped, red.
    test "refuses a struct even though a struct is a map" do
      assert Encryptor.Ecto.Map.cast(%URI{}, %{}) == :error
    end
  end

  describe "dump and load, with a tenant in scope" do
    scope_tenant "merchant_7f3"

    # sabotage: dump/3's map arm handing the value to Binary.dump/3 without
    # encoding it, red - Binary refuses a non-binary.
    test "round-trips a map through the serializer and the vault" do
      params = params(TestTypes.Metadata)

      assert {:ok, ciphertext} = TestTypes.Metadata.dump(@metadata, nil, params)
      assert is_binary(ciphertext)
      assert {:ok, @metadata} = TestTypes.Metadata.load(ciphertext, nil, params)
    end

    # sabotage: dump/3's nil clause deleted, red.
    test "leaves nil alone in both directions" do
      params = params(TestTypes.Metadata)

      assert TestTypes.Metadata.dump(nil, nil, params) == {:ok, nil}
      assert TestTypes.Metadata.load(nil, nil, params) == {:ok, nil}
    end

    # Decision 7: an empty map is a value, not an absence. sabotage: a
    # `dump(%{}, _, _), do: {:ok, nil}` clause added, red.
    test "encrypts the empty map rather than treating it as absent" do
      params = params(TestTypes.Metadata)

      assert {:ok, ciphertext} = TestTypes.Metadata.dump(%{}, nil, params)
      assert byte_size(ciphertext) > 0
      assert TestTypes.Metadata.load(ciphertext, nil, params) == {:ok, %{}}
    end

    # Decision 8, the consequence a host meets first. sabotage: a key
    # normalization added to cast/2, red - the two would match.
    test "a map cast with atom keys loads back with string keys" do
      params = params(TestTypes.Metadata)

      assert {:ok, ciphertext} = TestTypes.Metadata.dump(%{channel: "web"}, nil, params)
      assert TestTypes.Metadata.load(ciphertext, nil, params) == {:ok, %{"channel" => "web"}}
    end

    # sabotage: the stored bytes are the serializer's output encrypted, not the
    # serializer's output. Binary.dump/3's is_binary arm returning the value
    # unencrypted goes red here as well as in binary_test.
    test "the column holds ciphertext, not JSON" do
      assert {:ok, ciphertext} =
               TestTypes.Metadata.dump(@metadata, nil, params(TestTypes.Metadata))

      refute ciphertext =~ "channel"

      assert {:ok, json} =
               TestVaults.Merchant.decrypt(ciphertext,
                 key: "merchant_7f3",
                 encryption_context: %{"table" => "cards", "column" => "metadata"}
               )

      assert Jason.decode!(json) == @metadata
    end

    # sabotage: init/2's Map.put(:json, ...) hardcoded to Jason, red.
    test "uses the declared serializer rather than the default" do
      params = params(TestTypes.Sorted)

      assert {:ok, ciphertext} = TestTypes.Sorted.dump(%{"b" => 1, "a" => 2}, nil, params)

      assert {:ok, json} =
               TestVaults.Merchant.decrypt(ciphertext,
                 key: "merchant_7f3",
                 encryption_context: %{"table" => "cards", "column" => "metadata"}
               )

      assert json == ~s({"a":2,"b":1})
    end

    # sabotage: dump/3's catch-all delegating to Binary.dump/3 instead of
    # refusing, red - Binary's is_binary arm would encrypt the string and
    # return {:ok, ciphertext}, so a value that never passed cast/2 would be
    # stored rather than refused.
    test "refuses a non-map that reached dump without passing cast" do
      assert_raise ArgumentError, ~r/dump\/3 expects a plain map or nil.*a binary/s, fn ->
        TestTypes.Metadata.dump("channel=web", nil, params(TestTypes.Metadata))
      end
    end

    # sabotage: refuse_non_map!/2 interpolating the value, red.
    test "names the shape of the refused value and never the value" do
      params = params(TestTypes.Metadata)

      for {value, shape} <- [
            {:web, "an atom"},
            {12, "an integer"},
            {1.5, "a float"},
            {"secret", "a binary"},
            {["secret"], "a list"},
            {{:secret}, "a tuple"},
            {%URI{}, "a URI struct"},
            {self(), "a term of another type"}
          ] do
        error =
          assert_raise ArgumentError, fn -> TestTypes.Metadata.dump(value, nil, params) end

        assert error.message =~ shape
        refute error.message =~ "secret"
      end
    end

    # sabotage: load/3's catch-all clause deleted, red with a FunctionClauseError
    # that prints its arguments - which is the leak this arm exists to avoid.
    test "refuses a non-binary that reached load, through Binary's own message" do
      assert_raise ArgumentError, ~r/load\/3 expects a binary or nil/, fn ->
        TestTypes.Metadata.load(%{"channel" => "web"}, nil, params(TestTypes.Metadata))
      end
    end

    # sabotage: load/3 not delegating the decrypt to Binary.load/3, red.
    test "reports bytes that are not a well-formed message as an integrity event" do
      assert_raise DecryptError, fn ->
        TestTypes.Metadata.load(<<0, 1, 2, 3>>, nil, params(TestTypes.Metadata))
      end
    end

    # sabotage: the generated equal?/3 -> false, red.
    test "compares plaintext maps, and embeds as itself" do
      assert TestTypes.Metadata.equal?(@metadata, @metadata, %{})
      refute TestTypes.Metadata.equal?(@metadata, %{"channel" => "pos"}, %{})
      assert TestTypes.Metadata.embed_as(:json, %{}) == :self
      assert TestTypes.Metadata.type(%{}) == :binary
    end
  end

  describe "a serializer failure" do
    scope_tenant "merchant_7f3"

    # sabotage: encode!/2's {:error, reason} arm returning "{}" instead of
    # raising, red - a value the serializer could not encode would be stored
    # as an empty map and the failure would never reach the host.
    test "raises SerializationError on the way down, naming the direction" do
      error =
        assert_raise SerializationError, fn ->
          TestTypes.Unserializable.dump(@metadata, nil, params(TestTypes.Unserializable))
        end

      assert error.direction == :encode
      assert error.serializer == TestSerializers.Failing
      assert error.reason == {:serializer_raised, RuntimeError}
    end

    # sabotage: decode!/2's :decode detail reason -> :whatever, red.
    test "raises SerializationError on the way back, naming the direction" do
      # Written with a serializer that works, read with one that does not:
      # the shape a host meets when it changes :json without a migration.
      assert {:ok, ciphertext} =
               TestTypes.Metadata.dump(@metadata, nil, params(TestTypes.Metadata))

      error =
        assert_raise SerializationError, fn ->
          TestTypes.Unserializable.load(ciphertext, nil, params(TestTypes.Unserializable))
        end

      assert error.direction == :decode
      assert error.reason == {:serializer_raised, RuntimeError}
    end

    # sabotage: decode!/2's `when is_map(decoded) and not is_struct(decoded)`
    # guard -> `when true`, red - a list would be handed back as though it
    # were a map.
    test "raises when the payload parses into something that is not a map" do
      assert {:ok, ciphertext} =
               TestTypes.Metadata.dump(@metadata, nil, params(TestTypes.Metadata))

      error =
        assert_raise SerializationError, fn ->
          TestTypes.Listy.load(ciphertext, nil, params(TestTypes.Listy))
        end

      assert error.reason == {:not_a_map, :list}

      # The tag is an atom rather than a phrase because Error.redact/1 renders
      # any binary as its byte count: {:not_a_map, "a list"} would reach a host
      # as {:not_a_map, <<redacted 6 bytes>>}.
      assert Exception.message(error) =~ "{:not_a_map, :list}"
    end

    # ADR-0001 decision 6, and the reason detail/3 discards the rescued
    # exception rather than folding its message in. sabotage: run/1 handing
    # back {:error, exception} instead of the module, red - the protocol error
    # Jason raises carries the value it choked on.
    test "carries no plaintext into the message or the Inspect form" do
      # A tuple is the thing Jason cannot encode, so the default serializer
      # fails on a map that carries one.
      error =
        assert_raise SerializationError, fn ->
          TestTypes.Metadata.dump(
            %{"pan" => {:secret, "4111111111111111"}},
            nil,
            params(TestTypes.Metadata)
          )
        end

      for rendered <- [Exception.message(error), inspect(error)] do
        refute rendered =~ "4111111111111111"
        refute rendered =~ "secret"
        assert rendered =~ "cards"
        assert rendered =~ "metadata"
      end
    end

    # sabotage: detail/3's context_keys -> [], red.
    test "carries the same identifying values every exception in the family does" do
      error =
        assert_raise SerializationError, fn ->
          TestTypes.Unserializable.dump(@metadata, nil, params(TestTypes.Unserializable))
        end

      assert error.table == "cards"
      assert error.column == "metadata"
      assert error.context_keys == ["column", "table"]
      # The serializer runs outside the tenant-resolved part of the call, and
      # this layer resolves none of its own.
      assert error.tenant == nil
    end
  end

  describe "the tenant rules are Binary's" do
    # sabotage: dump/3 delegating past Binary's tenant resolution, red.
    test "a dump with no tenant in scope raises" do
      Tenant.clear()

      assert_raise MissingTenantError, ~r/cards/, fn ->
        TestTypes.Metadata.dump(@metadata, nil, params(TestTypes.Metadata))
      end
    end
  end
end
