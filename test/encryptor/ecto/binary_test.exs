defmodule Encryptor.Ecto.BinaryTest do
  use ExUnit.Case, async: true

  import Encryptor.Ecto.TenantScope

  alias Encryptor.Ecto.Binary
  alias Encryptor.Ecto.DecryptError
  alias Encryptor.Ecto.EncryptError
  alias Encryptor.Ecto.MissingContextError
  alias Encryptor.Ecto.MissingTenantError
  alias Encryptor.Ecto.Tenant
  alias Encryptor.Ecto.TestSchemas.Card
  alias Encryptor.Ecto.TestTypes
  alias Encryptor.Ecto.TestVaults

  doctest Encryptor.Ecto.Binary

  # A card number shaped like a real one, and the single value every test in
  # this file encrypts. It is a plaintext, so no assertion renders it into a
  # failure message beyond comparing it.
  @pan "4111111111111111"

  defp params(type, field \\ :pan), do: type.init(schema: Card, field: field)

  describe "the option set" do
    # sabotage: validate_declaration!/2's unknown-option case arm -> :ok, red.
    test "refuses an option outside the closed set, while the host compiles" do
      assert_raise ArgumentError, ~r/unknown option \[:searchable\]/, fn ->
        defmodule Searchable do
          use Encryptor.Ecto.Binary,
            vault: Encryptor.Ecto.TestVaults.Merchant,
            searchable: true
        end
      end
    end

    # sabotage: the missing-:vault check inverted to has_key?, red.
    test "refuses a declaration with no vault" do
      assert_raise ArgumentError, ~r/requires a :vault/, fn ->
        defmodule NoVault do
          use Encryptor.Ecto.Binary, tenant: :none
        end
      end
    end

    # sabotage: the Keyword.keyword?/1 guard dropped, red.
    test "refuses options that are not a keyword list" do
      assert_raise ArgumentError, ~r/expects a keyword list/, fn ->
        Binary.validate_declaration!(SomeModule, %{vault: TestVaults.App})
      end
    end

    # sabotage: validated_tenant/1's catch-all arm -> the value, red.
    test "refuses a tenant strategy that is neither an atom strategy nor a module" do
      assert_raise ArgumentError, ~r/expected :tenant to be :scope, :none, or a module/, fn ->
        Binary.init([vault: TestVaults.App, tenant: "merchant_7f3"], schema: Card, field: :pan)
      end
    end

    # sabotage: validated_context/1's valid? -> true, red.
    test "refuses a context that is not a map of strings to strings" do
      assert_raise ArgumentError, ~r/expected :context to be a map of string keys/, fn ->
        Binary.init([vault: TestVaults.App, context: %{purpose: :pii}], schema: Card, field: :pan)
      end
    end

    # sabotage: the :legacy check in init/2 removed, red.
    test "refuses :legacy rather than accepting it and doing nothing" do
      assert_raise ArgumentError, ~r/:legacy option .* not implemented yet \(ece-e8k\)/s, fn ->
        Binary.init([vault: TestVaults.App, legacy: SomeOldType], schema: Card, field: :pan)
      end
    end
  end

  describe "the declared context" do
    # sabotage: derive_table/1's Module.open? branch -> nil, red.
    test "derives the table from the schema's source and the column from the field" do
      assert %{table: "cards", column: "pan"} = params(TestTypes.Pan)
      assert %{table: "cards", column: "notes"} = params(TestTypes.Notes, :notes)
    end

    # sabotage: declared_value/4's binary arm falling through to derive, red.
    test "prefers the declaration's own values over the derived ones" do
      assert %{table: "cards", column: "pan"} = TestTypes.Pinned.init(schema: Card, field: :notes)
    end

    # sabotage: declared_value/4's `|| raise` replaced with `|| "unknown"`, red.
    test "raises when neither derivable nor supplied" do
      assert_raise ArgumentError, ~r/could not derive the declared table/, fn ->
        TestTypes.Pan.init([])
      end
    end

    # sabotage: derive_column/1's atom arm -> nil, red.
    test "raises for a derivable table and an underivable column" do
      assert_raise ArgumentError, ~r/could not derive the declared column/, fn ->
        TestTypes.Pan.init(schema: Card)
      end
    end

    # sabotage: source_of/1's function_exported? branch -> nil, red.
    test "reads the source off a schema module that has finished compiling" do
      assert %{table: "cards"} = TestTypes.Pan.init(schema: Card, field: :pan)
    end
  end

  describe "the simple callbacks" do
    # sabotage: type/1 -> :string, red.
    test "type is :binary whatever the plaintext was" do
      assert TestTypes.Pan.type(params(TestTypes.Pan)) == :binary
    end

    # sabotage: cast/2's catch-all -> {:ok, nil}, red.
    test "cast keeps the ordinary error arm and never encrypts" do
      assert TestTypes.Pan.cast(@pan, %{}) == {:ok, @pan}
      assert TestTypes.Pan.cast(nil, %{}) == {:ok, nil}
      assert TestTypes.Pan.cast(:not_a_binary, %{}) == :error
      assert TestTypes.Pan.cast(%{}, %{}) == :error
    end

    # sabotage: equal?/3 -> false, red.
    test "equal? compares plaintext" do
      assert TestTypes.Pan.equal?(@pan, @pan, %{})
      refute TestTypes.Pan.equal?(@pan, "4111111111111112", %{})
    end

    # sabotage: embed_as/2 -> :dump, red.
    test "embed_as is :self" do
      assert TestTypes.Pan.embed_as(:json, %{}) == :self
    end
  end

  describe "dump and load, with a tenant in scope" do
    scope_tenant "merchant_7f3"

    # sabotage: dump/3's is_binary arm returning {:ok, value} unencrypted, red.
    test "round-trips a value through the vault" do
      params = params(TestTypes.Pan)

      assert {:ok, ciphertext} = TestTypes.Pan.dump(@pan, nil, params)
      assert is_binary(ciphertext)
      refute ciphertext == @pan
      assert {:ok, @pan} = TestTypes.Pan.load(ciphertext, nil, params)
    end

    # sabotage: the same arm, since a passthrough dump is deterministic, red.
    test "produces different bytes for the same plaintext every time" do
      params = params(TestTypes.Pan)

      assert {:ok, first} = TestTypes.Pan.dump(@pan, nil, params)
      assert {:ok, second} = TestTypes.Pan.dump(@pan, nil, params)

      refute first == second
    end

    # sabotage: dump/3's nil clause deleted so nil falls to the binary arm, red.
    test "leaves nil alone in both directions" do
      params = params(TestTypes.Pan)

      assert TestTypes.Pan.dump(nil, nil, params) == {:ok, nil}
      assert TestTypes.Pan.load(nil, nil, params) == {:ok, nil}
    end

    # sabotage: dump/3 gaining a `dump("", _, _), do: {:ok, nil}` clause, red.
    test "encrypts an empty binary rather than treating it as absent" do
      params = params(TestTypes.Pan)

      assert {:ok, ciphertext} = TestTypes.Pan.dump("", nil, params)
      assert byte_size(ciphertext) > 0
      assert TestTypes.Pan.load(ciphertext, nil, params) == {:ok, ""}
    end

    # sabotage: encryption_context/1 dropping the "column" pair, red.
    test "binds the column, so one column's bytes do not load as another's" do
      assert {:ok, ciphertext} = TestTypes.Pan.dump(@pan, nil, params(TestTypes.Pan))

      assert_raise DecryptError, fn ->
        TestTypes.Notes.load(ciphertext, nil, params(TestTypes.Notes, :notes))
      end
    end

    # sabotage: vault_opts/2 passing the tenant as a context pair instead of
    # key:, red - the vault refuses a caller-supplied tenant pair.
    test "passes the tenant as the key and supplies exactly table and column" do
      assert {:ok, ciphertext} = TestTypes.Pan.dump(@pan, nil, params(TestTypes.Pan))

      # The vault, called directly with the context this layer claims to
      # compose, opens the message. If the type had supplied a different set,
      # this decrypt would fail authentication.
      assert {:ok, @pan} =
               TestVaults.Merchant.decrypt(ciphertext,
                 key: "merchant_7f3",
                 encryption_context: %{"table" => "cards", "column" => "pan"}
               )
    end

    # sabotage: load/3's is_binary arm returning {:ok, value} unchanged, red.
    test "reports bytes that are not a well-formed message as an integrity event" do
      assert_raise DecryptError, fn ->
        TestTypes.Pan.load(<<0, 1, 2, 3>>, nil, params(TestTypes.Pan))
      end
    end
  end

  describe "a wrong tenant" do
    # sabotage: encryption_context/1 dropping the "table" pair (the tenant
    # would still separate them, but the AAD binding under test is the one
    # this arm relies on), red.
    test "fails authentication rather than reading across the boundary" do
      params = params(TestTypes.Pan)

      ciphertext =
        Tenant.wrap("merchant_7f3", fn ->
          {:ok, bytes} = TestTypes.Pan.dump(@pan, nil, params)
          bytes
        end)

      Tenant.wrap("merchant_a19", fn ->
        assert_raise DecryptError, fn -> TestTypes.Pan.load(ciphertext, nil, params) end
      end)
    end
  end

  describe "no tenant in scope" do
    setup do
      Tenant.clear()
    end

    # sabotage: resolve_tenant!/2's {:error, _} arm returning "default", red.
    test "a dump raises, naming the table and the column" do
      error =
        assert_raise MissingTenantError, fn ->
          TestTypes.Pan.dump(@pan, nil, params(TestTypes.Pan))
        end

      message = Exception.message(error)
      assert message =~ ~s(table: "cards")
      assert message =~ ~s(column: "pan")
      assert message =~ "no_tenant_in_scope"
    end

    # sabotage: the same arm - decision 5d says a load raises the same way, red.
    test "a load raises the same way" do
      assert_raise MissingTenantError, fn ->
        TestTypes.Pan.load(<<0, 1, 2, 3>>, nil, params(TestTypes.Pan))
      end
    end

    # sabotage: the MissingTenantError raise replaced by one carrying the
    # value, red.
    test "the failure carries no plaintext, in its message or its inspect" do
      error =
        assert_raise MissingTenantError, fn ->
          TestTypes.Pan.dump(@pan, nil, params(TestTypes.Pan))
        end

      refute Exception.message(error) =~ @pan
      refute inspect(error) =~ @pan
    end
  end

  describe "a host resolver" do
    setup do
      Tenant.clear()
    end

    # sabotage: resolver/1's module clause -> TenantContext.Scope, red.
    test "is asked instead of the process scope" do
      params = params(TestTypes.Resolved)

      assert {:ok, ciphertext} = TestTypes.Resolved.dump(@pan, nil, params)
      assert {:ok, @pan} = TestTypes.Resolved.load(ciphertext, nil, params)
    end

    # sabotage: resolve_tenant!/2's {:error, _} arm -> :none, red.
    test "that refuses drives the same raise an empty scope does" do
      assert_raise MissingTenantError, fn ->
        TestTypes.Refusing.dump(@pan, nil, params(TestTypes.Refusing))
      end
    end

    # sabotage: resolve_tenant!/2's off-contract arm deleted, red (a
    # FunctionClauseError is not a MissingTenantError).
    test "that answers off contract raises rather than guessing" do
      error =
        assert_raise MissingTenantError, fn ->
          TestTypes.OffContract.dump(@pan, nil, params(TestTypes.OffContract))
        end

      assert Exception.message(error) =~ "resolver_off_contract"
    end
  end

  describe "a field declared tenant: :none" do
    setup do
      Tenant.clear()
    end

    # sabotage: resolve_tenant!/2's :none clause deleted, red - the field
    # would consult the scope and raise.
    test "round-trips with no tenant anywhere in sight" do
      params = TestTypes.Global.init(schema: Card, field: :notes)

      assert {:ok, ciphertext} = TestTypes.Global.dump(@pan, nil, params)
      assert {:ok, @pan} = TestTypes.Global.load(ciphertext, nil, params)
    end
  end

  describe "a vault failure" do
    scope_tenant "merchant_7f3"

    # sabotage: dump/3's {:error, %Error{}} arm returning {:ok, value}, red.
    test "on encrypt raises EncryptError rather than returning :error" do
      params = TestTypes.Unstarted.init(schema: Card, field: :pan)

      error = assert_raise EncryptError, fn -> TestTypes.Unstarted.dump(@pan, nil, params) end
      assert Exception.message(error) =~ "vault_not_started"
    end

    # sabotage: the {:missing_required_context_keys, _} arm removed so the
    # generic EncryptError arm catches it, red.
    test "naming a context key this field does not supply gets its own exception" do
      params = TestTypes.Strict.init(schema: Card, field: :pan)

      error = assert_raise MissingContextError, fn -> TestTypes.Strict.dump(@pan, nil, params) end
      assert Exception.message(error) =~ "purpose"
    end
  end

  describe "a value that is not a binary" do
    scope_tenant "merchant_7f3"

    # sabotage: refuse_non_binary!/3 replaced by inspect(value) in the
    # message, red.
    test "is refused by dump without its value reaching the message" do
      error =
        assert_raise ArgumentError, fn ->
          TestTypes.Pan.dump(%{pan: @pan}, nil, params(TestTypes.Pan))
        end

      message = Exception.message(error)
      assert message =~ "cards.pan"
      assert message =~ "expects a binary or nil"
      assert message =~ "a map"
      refute message =~ @pan
    end

    # sabotage: load/3's catch-all clause deleted, red.
    test "is refused by load the same way" do
      assert_raise ArgumentError, ~r/load\/3 expects a binary or nil/, fn ->
        TestTypes.Pan.load(:not_bytes, nil, params(TestTypes.Pan))
      end
    end
  end

  describe "declarations the derivation cannot serve" do
    # sabotage: declared_value/4's `other ->` arm returning the value, red.
    test "refuse a declared table that is not a non-empty string" do
      assert_raise ArgumentError, ~r/expected :table to be a non-empty string/, fn ->
        Binary.init([vault: TestVaults.App, table: 123], schema: Card, field: :pan)
      end
    end

    # sabotage: derive_table/1's binary arm -> nil, red.
    test "accept a source given as a string, the way a schemaless use passes it" do
      assert %{table: "cards", column: "pan"} =
               TestTypes.Pan.init(schema: "cards", field: :pan)
    end

    # sabotage: source_of/1's `true -> nil` arm -> "cards", red.
    test "refuse a schema module that is not an Ecto schema" do
      assert_raise ArgumentError, ~r/could not derive the declared table/, fn ->
        TestTypes.Pan.init(schema: Encryptor.Ecto.TestResolvers.Fixed, field: :pan)
      end
    end

    # sabotage: source_of/1's Module.open? arm -> nil, red. This is the arm
    # the ordinary path takes: at the moment a field is declared, the schema
    # module is still compiling and has no __schema__/1 yet. Defining the
    # schema inside the test is what puts that arm under measurement.
    test "read the source off a schema module that is still compiling" do
      defmodule LiveSchema do
        use Ecto.Schema

        schema "signup_attempts" do
          field(:variant, Encryptor.Ecto.TestTypes.Pan)
        end
      end

      assert {:parameterized, {_type, %{table: "signup_attempts", column: "variant"}}} =
               LiveSchema.__schema__(:type, :variant)
    end

    # sabotage: validated_context/1's is_map/1 half dropped from valid?, red.
    test "refuse a context that is not a map at all" do
      assert_raise ArgumentError, ~r/expected :context to be a map of string keys/, fn ->
        Binary.init([vault: TestVaults.App, context: "pii"], schema: Card, field: :pan)
      end
    end

    # sabotage: describe_field/1's {nil, field} arm -> "an encrypted field", red.
    test "name the field alone when there is no schema to name" do
      assert_raise ArgumentError, ~r/^:pan: the :legacy option/, fn ->
        Binary.init([vault: TestVaults.App, legacy: SomeOldType], field: :pan)
      end
    end
  end

  describe "a resolver that declares the value global" do
    setup do
      Tenant.clear()
    end

    # sabotage: resolve_tenant!/2's `:none ->` arm deleted, red - the value
    # would fall to the off-contract arm and raise.
    test "round-trips with no key passed to the vault" do
      params = TestTypes.Declining.init(schema: Card, field: :notes)

      assert {:ok, ciphertext} = TestTypes.Declining.dump(@pan, nil, params)
      assert {:ok, @pan} = TestTypes.Declining.load(ciphertext, nil, params)
    end
  end

  describe "a decrypt against a vault requiring more context than the field supplies" do
    # sabotage: load/3's {:missing_required_context_keys, _} arm removed so
    # the generic DecryptError arm catches it, red.
    test "is reported as a misconfiguration, not as an integrity event" do
      # Written through the App vault, which requires only the column pair,
      # and read through a field pointed at Strict, which also requires
      # "purpose". Same key material, so what fails is the required set.
      params = TestTypes.Global.init(schema: Card, field: :pan)
      assert {:ok, ciphertext} = TestTypes.Global.dump(@pan, nil, params)

      strict = TestTypes.Strict.init(schema: Card, field: :pan)

      error =
        assert_raise MissingContextError, fn ->
          TestTypes.Strict.load(ciphertext, nil, strict)
        end

      assert Exception.message(error) =~ "purpose"
    end
  end

  describe "the shape a refused value is reported as" do
    scope_tenant "merchant_7f3"

    # sabotage: any one shape_of/1 clause falling through to the catch-all, red.
    test "names the kind of term without rendering it" do
      params = params(TestTypes.Pan)

      for {value, shape} <- [
            {:pan, "an atom"},
            {4_111, "an integer"},
            {4.11, "a float"},
            {[@pan], "a list"},
            {%{pan: @pan}, "a map"},
            {{:pan, @pan}, "a tuple"},
            {self(), "a term of another type"}
          ] do
        error = assert_raise ArgumentError, fn -> TestTypes.Pan.dump(value, nil, params) end
        message = Exception.message(error)

        assert message =~ shape
        refute message =~ @pan
      end
    end
  end
end
