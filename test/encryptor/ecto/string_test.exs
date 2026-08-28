defmodule Encryptor.Ecto.StringTest do
  use ExUnit.Case, async: true

  import Encryptor.Ecto.TenantScope

  alias Encryptor.Ecto.DecryptError
  alias Encryptor.Ecto.MissingTenantError
  alias Encryptor.Ecto.Tenant
  alias Encryptor.Ecto.TestSchemas.Card
  alias Encryptor.Ecto.TestTypes
  alias Encryptor.Ecto.TestVaults

  doctest Encryptor.Ecto.String

  # A cardholder name, the plaintext every test in this file encrypts. It is a
  # plaintext, so no assertion renders it into a failure message beyond
  # comparing it.
  @name "Ada Lovelace"

  defp params(type, field \\ :holder_name), do: type.init(schema: Card, field: field)

  describe "the option set" do
    # sabotage: validate_declaration!/4's `known` -> @known_options ignoring
    # extra_options would not show here, but the declared_by threading would:
    # the message would name Binary. Reverting it to the literal
    # "Encryptor.Ecto.Binary" goes red.
    test "names the macro the host actually wrote when an option is outside the set" do
      assert_raise ArgumentError,
                   ~r/unknown option \[:searchable\] for use Encryptor.Ecto.String/,
                   fn ->
                     defmodule Searchable do
                       use Encryptor.Ecto.String,
                         vault: Encryptor.Ecto.TestVaults.Merchant,
                         searchable: true
                     end
                   end
    end

    # sabotage: the same threading in missing_vault_message/2, red.
    test "names the macro the host actually wrote when the vault is missing" do
      assert_raise ArgumentError, ~r/use Encryptor.Ecto.String requires a :vault/, fn ->
        defmodule NoVault do
          use Encryptor.Ecto.String, tenant: :none
        end
      end
    end

    # sabotage: validate_declaration!/4's extra_options argument, passed as
    # [] at string.ex's /2 wrapper, changed to [:json]. Red.
    test "refuses :json, which belongs to Map alone" do
      assert_raise ArgumentError, ~r/unknown option \[:json\]/, fn ->
        defmodule Serialized do
          use Encryptor.Ecto.String,
            vault: Encryptor.Ecto.TestVaults.Merchant,
            json: Jason
        end
      end
    end
  end

  describe "cast" do
    # sabotage: the String.valid?/1 branch -> {:ok, value}, red.
    test "accepts valid UTF-8 and refuses bytes that are not" do
      assert TestTypes.HolderName.cast(@name, %{}) == {:ok, @name}
      assert TestTypes.HolderName.cast("Ada Lovelacé", %{}) == {:ok, "Ada Lovelacé"}
      assert TestTypes.HolderName.cast("", %{}) == {:ok, ""}
      assert TestTypes.HolderName.cast(nil, %{}) == {:ok, nil}
      assert TestTypes.HolderName.cast(<<0xFF, 0xFE>>, %{}) == :error
    end

    # sabotage: cast/2's catch-all -> {:ok, nil}, red.
    test "refuses a value that is not a binary at all" do
      assert TestTypes.HolderName.cast(:not_a_string, %{}) == :error
      assert TestTypes.HolderName.cast(42, %{}) == :error
      assert TestTypes.HolderName.cast(%{}, %{}) == :error
    end

    # This is the difference between the two types, and the reason a host
    # picks one over the other. sabotage: the same String.valid?/1 branch, red.
    test "is where String and Binary differ, and nowhere else" do
      invalid = <<0xFF, 0xFE>>

      assert TestTypes.Pan.cast(invalid, %{}) == {:ok, invalid}
      assert TestTypes.HolderName.cast(invalid, %{}) == :error
    end
  end

  describe "everything below cast is Binary's" do
    scope_tenant "merchant_7f3"

    # sabotage: the generated type/1 delegating to something other than
    # Binary.type/1, red.
    test "the column is :binary, not :text" do
      assert TestTypes.HolderName.type(params(TestTypes.HolderName)) == :binary
    end

    # sabotage: the generated dump/3 returning {:ok, value}, red.
    test "round-trips through the vault" do
      params = params(TestTypes.HolderName)

      assert {:ok, ciphertext} = TestTypes.HolderName.dump(@name, nil, params)
      refute ciphertext == @name
      assert {:ok, @name} = TestTypes.HolderName.load(ciphertext, nil, params)
    end

    # sabotage: the generated init/1 dropping the derived column, red.
    test "binds the same declared table and column Binary would" do
      assert %{table: "cards", column: "holder_name"} = params(TestTypes.HolderName)

      assert {:ok, ciphertext} =
               TestTypes.HolderName.dump(@name, nil, params(TestTypes.HolderName))

      assert {:ok, @name} =
               TestVaults.Merchant.decrypt(ciphertext,
                 key: "merchant_7f3",
                 encryption_context: %{"table" => "cards", "column" => "holder_name"}
               )
    end

    # sabotage: dump/3's nil clause deleted, red.
    test "leaves nil alone and encrypts the empty string" do
      params = params(TestTypes.HolderName)

      assert TestTypes.HolderName.dump(nil, nil, params) == {:ok, nil}
      assert TestTypes.HolderName.load(nil, nil, params) == {:ok, nil}

      assert {:ok, ciphertext} = TestTypes.HolderName.dump("", nil, params)
      assert byte_size(ciphertext) > 0
      assert TestTypes.HolderName.load(ciphertext, nil, params) == {:ok, ""}
    end

    # sabotage: the generated load/3 returning the stored bytes unchanged, red.
    test "reports bytes that are not a well-formed message as an integrity event" do
      assert_raise DecryptError, fn ->
        TestTypes.HolderName.load(<<0, 1, 2, 3>>, nil, params(TestTypes.HolderName))
      end
    end

    # sabotage: the generated equal?/3 -> false, red.
    test "compares plaintext, and embeds as itself" do
      assert TestTypes.HolderName.equal?(@name, @name, %{})
      refute TestTypes.HolderName.equal?(@name, "Grace Hopper", %{})
      assert TestTypes.HolderName.embed_as(:json, %{}) == :self
    end

    # A load does not re-check validity: the exception family is fixed by
    # ADR-0001 decision 6, and adding a class to it is a decision rather than
    # an implementation detail. sabotage: a String.valid?/1 check added to the
    # generated load/3, red.
    test "loads back whatever was written, without re-checking validity" do
      params = params(TestTypes.HolderName)

      # Written through Binary, which accepts the bytes, and read through
      # String - the shape a migration onto this type produces. The same params
      # go to both calls, so the encryption context is identical and only the
      # type differs.
      assert {:ok, ciphertext} = TestTypes.Pan.dump(<<0xFF, 0xFE>>, nil, params)

      assert TestTypes.HolderName.load(ciphertext, nil, params) == {:ok, <<0xFF, 0xFE>>}
    end
  end

  describe "the tenant rules are Binary's too" do
    # sabotage: the generated dump/3 delegating past Binary's tenant
    # resolution, red.
    test "a dump with no tenant in scope raises" do
      Tenant.clear()

      assert_raise MissingTenantError, ~r/cards/, fn ->
        TestTypes.HolderName.dump(@name, nil, params(TestTypes.HolderName))
      end
    end

    # sabotage: the generated init/1 not carrying `tenant: :none` through, red.
    test "a field declared global asks no resolver anything" do
      Tenant.clear()
      params = TestTypes.GlobalName.init(schema: Card, field: :holder_name)

      assert {:ok, ciphertext} = TestTypes.GlobalName.dump(@name, nil, params)
      assert TestTypes.GlobalName.load(ciphertext, nil, params) == {:ok, @name}
    end
  end
end
