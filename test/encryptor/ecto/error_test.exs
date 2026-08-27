defmodule Encryptor.Ecto.ErrorTest do
  use ExUnit.Case, async: true

  alias Encryptor.Ecto.DecryptError
  alias Encryptor.Ecto.EncryptError
  alias Encryptor.Ecto.Error
  alias Encryptor.Ecto.MissingContextError
  alias Encryptor.Ecto.MissingTenantError
  alias Encryptor.Ecto.SerializationError

  doctest Encryptor.Ecto.Error

  @family [
    MissingTenantError,
    MissingContextError,
    EncryptError,
    DecryptError,
    SerializationError
  ]

  # A plaintext from the canonical card-processing example, and a key-shaped
  # binary. Neither may appear in any rendered output, per ADR-0001 decision 6.
  @plaintext "4111111111111111"
  @key_material String.duplicate("A7", 16)

  describe "the family's common shape" do
    # sabotage: drop :reason from __using__/1's common field list -> red
    test "every member carries the four identifying values and the tenant" do
      for module <- @family do
        error = build(module)

        assert %{
                 table: "payments",
                 column: "card_number",
                 context_keys: ["table", "column"],
                 tenant: "tenant_42",
                 reason: :decrypt_failed
               } = error
      end
    end

    # sabotage: drop :reason from __using__/1's common field list -> red
    test "every member is an exception whose message/1 Exception dispatches to" do
      for module <- @family do
        error = build(module)

        assert Exception.message(error) == module.message(error)
        assert Exception.message(error) =~ module.headline()
      end
    end

    # sabotage: drop the {"table", ...} pair from common_detail/1 -> red
    test "message/1 names the declared table, column, context keys and tenant" do
      message = Exception.message(build(EncryptError))

      assert message =~ ~s(table: "payments")
      assert message =~ ~s(column: "card_number")
      assert message =~ ~s(context keys: ["table", "column"])
      assert message =~ ~s(tenant: "tenant_42")
      assert message =~ "reason: :decrypt_failed"
    end
  end

  describe "redact/1" do
    # sabotage: make the is_atom clause return "<redacted>" -> red
    test "atoms and integers survive verbatim" do
      assert Error.redact(:decrypt_failed) == ":decrypt_failed"
      assert Error.redact(nil) == "nil"
      assert Error.redact(Jason) == "Jason"
      assert Error.redact(42) == "42"
    end

    # sabotage: make the is_binary clause return the binary itself -> red
    test "a binary is reduced to its byte count" do
      assert Error.redact(@plaintext) == "<<redacted 16 bytes>>"
      assert Error.redact(@key_material) == "<<redacted 32 bytes>>"
      refute Error.redact(@plaintext) =~ @plaintext
    end

    # sabotage: make the is_binary clause return the binary itself -> red
    test "a binary nested in a tuple or a list is redacted in place" do
      assert Error.redact({:decrypt_failed, @plaintext}) ==
               "{:decrypt_failed, <<redacted 16 bytes>>}"

      assert Error.redact([:a, [@plaintext]]) == "[:a, [<<redacted 16 bytes>>]]"
    end

    # sabotage: make the catch-all clause return inspect(term) -> red
    test "a map, a struct and a float are redacted wholesale" do
      refute Error.redact(%{card_number: @plaintext}) =~ @plaintext
      assert Error.redact(%{card_number: @plaintext}) == "<redacted>"
      assert Error.redact(%ArgumentError{message: @plaintext}) == "<redacted>"
      assert Error.redact(1.5) == "<redacted>"
    end
  end

  describe "the prohibition on leaking values" do
    # sabotage: make the is_binary clause of redact/1 return the binary -> red
    test "no member leaks a plaintext or key material through message/1" do
      for module <- @family do
        message = Exception.message(secret_error(module))

        refute message =~ @plaintext
        refute message =~ @key_material
      end
    end

    # sabotage: make __using__/1's Inspect impl fall back to the derived one -> red
    test "no member leaks a plaintext or key material through Inspect" do
      for module <- @family do
        rendered = inspect(secret_error(module))

        refute rendered =~ @plaintext
        refute rendered =~ @key_material
      end
    end

    # sabotage: make __using__/1's Inspect impl fall back to the derived one -> red
    test "Inspect is overridden rather than derived" do
      for module <- @family do
        rendered = inspect(build(module))

        assert String.starts_with?(rendered, "##{inspect(module)}<")
        refute rendered =~ "%#{inspect(module)}{"
      end
    end

    # sabotage: drop the {"table", ...} pair from common_detail/1 -> red
    test "Inspect carries the same identifying values as message/1" do
      rendered = inspect(build(EncryptError))

      assert rendered =~ ~s(table: "payments")
      assert rendered =~ ~s(column: "card_number")
      assert rendered =~ "reason: :decrypt_failed"
    end
  end

  describe "DecryptError" do
    # sabotage: rename :engine off DecryptError's extra_fields list -> red
    test "carries the non-contractual engine detail" do
      assert %DecryptError{engine: {:encryption_context_mismatch, "table"}} =
               struct!(DecryptError, engine: {:encryption_context_mismatch, "table"})
    end

    # sabotage: drop the {"engine", ...} pair from extra_detail/1 -> red
    test "renders the engine tag while redacting the binary inside it" do
      message =
        Exception.message(
          struct!(DecryptError, engine: {:encryption_context_mismatch, @key_material})
        )

      assert message =~ "engine: {:encryption_context_mismatch, <<redacted 32 bytes>>}"
    end
  end

  describe "MissingContextError" do
    # sabotage: drop the {"missing keys", ...} pair from extra_detail/1 -> red
    test "names the context keys the vault reported missing" do
      message = Exception.message(struct!(MissingContextError, missing_keys: ["tenant_ref"]))

      assert message =~ ~s(missing keys: ["tenant_ref"])
    end

    # sabotage: change headline/0 to DecryptError's wording -> red
    test "reads as a host misconfiguration, not as an integrity event" do
      assert MissingContextError.headline() =~ "requires encryption-context keys"
      refute MissingContextError.headline() =~ "decrypt"
    end
  end

  describe "SerializationError" do
    # sabotage: drop the {"serializer", ...} pair from extra_detail/1 -> red
    test "names the serializer module and the failing direction" do
      message =
        Exception.message(struct!(SerializationError, serializer: Jason, direction: :encode))

      assert message =~ "serializer: Jason"
      assert message =~ "direction: :encode"
    end
  end

  describe "MissingTenantError" do
    # sabotage: change headline/0 to omit "no tenant in scope" -> red
    test "reports an empty scope rather than a resolved tenant" do
      assert %MissingTenantError{tenant: nil} = struct!(MissingTenantError, [])
      assert MissingTenantError.headline() =~ "no tenant in scope"
    end

    # sabotage: make message/1 return only the headline -> red
    test "raises with the declared table and column in its message" do
      assert_raise MissingTenantError, ~r/table: "payments".*column: "card_number"/, fn ->
        raise MissingTenantError, table: "payments", column: "card_number"
      end
    end
  end

  defp build(module) do
    struct!(module, common())
  end

  defp secret_error(module) do
    struct!(
      module,
      Keyword.merge(common(),
        reason: {:decrypt_failed, @plaintext},
        tenant: "tenant_42"
      ) ++ extras(module)
    )
  end

  defp common do
    [
      table: "payments",
      column: "card_number",
      context_keys: ["table", "column"],
      tenant: "tenant_42",
      reason: :decrypt_failed
    ]
  end

  defp extras(DecryptError), do: [engine: {:encryption_context_mismatch, @key_material}]
  defp extras(MissingContextError), do: [missing_keys: ["tenant_ref"]]
  defp extras(SerializationError), do: [serializer: Jason, direction: :encode]
  defp extras(_module), do: []
end
