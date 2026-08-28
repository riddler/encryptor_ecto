defmodule Encryptor.Ecto.BlindIndex.DerivationTest do
  use ExUnit.Case, async: true

  alias Encryptor.Ecto.BlindIndex.Derivation
  alias Encryptor.Ecto.BlindIndex.DerivationError
  alias Encryptor.Ecto.MissingTenantError
  alias Encryptor.Ecto.Tenant

  doctest Encryptor.Ecto.BlindIndex.Derivation

  # Key-shaped test fixtures. They are still key-shaped, so they may appear in
  # this file and never in any rendered failure output.
  @key_material :binary.copy(<<0x0B>>, 32)
  @other_key_material :binary.copy(<<0x2A>>, 32)

  # A resolver that is not the default one, to prove decision 3a's claim that
  # the index asks the *field's* configured strategy rather than reading the
  # process scope itself.
  defmodule FixedResolver do
    @moduledoc false
    @behaviour Encryptor.Ecto.TenantContext

    @impl Encryptor.Ecto.TenantContext
    def resolve(_operation, _params), do: {:ok, "merchant_7f3"}
  end

  defmodule RefusingResolver do
    @moduledoc false
    @behaviour Encryptor.Ecto.TenantContext

    @impl Encryptor.Ecto.TenantContext
    def resolve(_operation, _params), do: {:error, :no_request_context}
  end

  defmodule OffContractResolver do
    @moduledoc false

    def resolve(_operation, _params), do: "merchant_7f3"
  end

  defmodule OperationResolver do
    @moduledoc false
    @behaviour Encryptor.Ecto.TenantContext

    @impl Encryptor.Ecto.TenantContext
    def resolve(operation, _params), do: {:ok, Atom.to_string(operation)}
  end

  defp card_number_index(overrides \\ []) do
    Derivation.new!(
      Keyword.merge(
        [table: "payments", column: "card_number", index_name: "card_number_index"],
        overrides
      )
    )
  end

  defp params(overrides \\ []) do
    Enum.into(overrides, %{
      vault: Payments.Vault,
      tenant: :scope,
      table: "payments",
      column: "card_number"
    })
  end

  # ADR-0003 decision 2 as amended 2026-08-27 (D1 and D2). Every expected value
  # below was produced by an independent HKDF-Expand(SHA-256) implementation
  # over the same two-step nesting, not by running this package.
  describe "golden vectors (ADR-0003 d2, amendments 1 and 2)" do
    # sabotage: change @outer_purpose to "blind_index" -> red
    test "the outer expansion is the reserved encryptor/v1/blind-index label" do
      assert Derivation.outer_label() == "encryptor/v1/blind-index"

      assert Encryptor.Kdf.derive_subkey(@key_material, "blind-index", 32)
             |> Base.encode16(case: :lower) ==
               "986a156297c53cc2b08ecb09dfec587c8cee164007e60b83b314a17ee8ae96d4"
    end

    # sabotage: change @info_prefix to "encryptor_ecto/blind_index/v2" -> red
    # sabotage: drop Integer.to_string(version) from info/1 -> red
    test "the info string is decision 2's, with the version D1 added" do
      assert Derivation.info(card_number_index()) ==
               "encryptor_ecto/blind_index/v1|payments|card_number|card_number_index|1"
    end

    # sabotage: reverse the two Kdf calls in derive/2 -> red
    # sabotage: change @key_bytes to 16 -> red
    test "the derived key is 32 pinned bytes" do
      key = Derivation.derive(card_number_index(), @key_material)

      assert byte_size(key) == 32

      assert Base.encode16(key, case: :lower) ==
               "5915d062aaf8433e7ac4fa18caf50ee3f27148e86079bd0f42bc00f94ef89eb1"
    end

    # sabotage: drop the version component from info/1 -> red. This is the
    # whole point of D1: without it decision 7's rotation rotates nothing.
    test "a version bump derives different bytes" do
      assert Derivation.derive(card_number_index(version: 2), @key_material)
             |> Base.encode16(case: :lower) ==
               "85784a9cd68d8dc19759b041282e071588f55293813f11006aefaa07a3d2b0b0"

      refute Derivation.derive(card_number_index(version: 2), @key_material) ==
               Derivation.derive(card_number_index(), @key_material)
    end

    # sabotage: drop index_name from info/1 -> red
    test "a second index over one column derives different bytes" do
      assert Derivation.derive(card_number_index(index_name: "card_number_lookup"), @key_material)
             |> Base.encode16(case: :lower) ==
               "188d8e908ca021a6001a801e5818be155fd6ab3cb3f7fae345d143b7c3d22005"
    end

    # sabotage: drop column from info/1 -> red
    test "a different column derives different bytes" do
      assert Derivation.derive(card_number_index(column: "billing_email"), @key_material)
             |> Base.encode16(case: :lower) ==
               "42db0ed001c2740922fef9264753bff60412ba12b2006dfc04f593692489b796"
    end

    # sabotage: drop table from info/1 -> red. This is the cross-table join
    # the consequence paragraph of decision 2 promises a host.
    test "a different table derives different bytes" do
      assert Derivation.derive(card_number_index(table: "signups"), @key_material)
             |> Base.encode16(case: :lower) ==
               "d3c09049859da6843185a1de10058ffe9e5f543b05ab7fc2c31f6365c4d50015"
    end

    # sabotage: ignore the key_material argument and use a module constant -> red
    test "different key material derives different bytes" do
      assert Derivation.derive(card_number_index(), @other_key_material)
             |> Base.encode16(case: :lower) ==
               "8dd5671b4e09c3cd4a0d5199069b6f95a42825e1027a298bb18b2c44cdcbc5ea"
    end

    # sabotage: seed the derivation with :crypto.strong_rand_bytes/1 -> red
    test "derivation is deterministic" do
      assert Derivation.derive(card_number_index(), @key_material) ==
               Derivation.derive(card_number_index(), @key_material)
    end
  end

  describe "new!/1" do
    # sabotage: change the version default from 1 to 2 -> red
    test "defaults version to 1 and scope to :tenant" do
      assert %Derivation{version: 1, scope: :tenant} = card_number_index()
    end

    # sabotage: delete validate_component!/2's separator branch -> red
    test "refuses a component carrying the info separator" do
      for key <- [:table, :column, :index_name] do
        error =
          assert_raise DerivationError, fn ->
            card_number_index([{key, "a|b"}])
          end

        assert error.reason == {:invalid, key, :contains_separator}
      end
    end

    # sabotage: widen validate_component!/2 guard to accept atoms -> red
    test "refuses a non-binary or empty component" do
      for key <- [:table, :column, :index_name], value <- [:an_atom, "", nil, 7] do
        error =
          assert_raise DerivationError, fn -> card_number_index([{key, value}]) end

        assert error.reason == {:invalid, key, :not_a_non_empty_binary}
      end
    end

    # sabotage: replace `version > 0` with `version >= 0` -> red
    test "refuses a version that is not a positive integer" do
      for value <- [0, -1, "1", nil, 1.0] do
        error =
          assert_raise DerivationError, fn -> card_number_index(version: value) end

        assert error.reason == {:invalid, :version, :not_a_positive_integer}
      end
    end

    # sabotage: delete validate_scope!/1's call from new!/1 -> red
    test "refuses a scope that is neither :tenant nor :global" do
      error = assert_raise DerivationError, fn -> card_number_index(scope: :everything) end

      assert error.reason == {:invalid, :scope, :not_tenant_or_global}
    end
  end

  describe "derive/2 argument checks" do
    # sabotage: delete validate_key_material!/2's call from derive/2 -> red
    test "refuses key material shorter than 32 bytes" do
      error =
        assert_raise DerivationError, fn ->
          Derivation.derive(card_number_index(), :binary.copy(<<0x0B>>, 31))
        end

      assert error.reason == {:invalid, :key_material, :shorter_than_32_bytes}
    end

    # sabotage: drop the non-binary clause of validate_key_material!/2 -> red
    test "refuses key material that is not a binary" do
      error =
        assert_raise DerivationError, fn -> Derivation.derive(card_number_index(), :none) end

      assert error.reason == {:invalid, :key_material, :not_a_binary}
    end
  end

  describe "selector!/3 (ADR-0003 decision 3a)" do
    setup do
      Tenant.clear()
      on_exit(&Tenant.clear/0)
    end

    # sabotage: make the :global clause fall through to the :tenant one -> red
    test "a :global index asks no resolver anything" do
      assert Derivation.selector!(
               card_number_index(scope: :global),
               params(tenant: RefusingResolver),
               :dump
             ) == :global
    end

    # sabotage: read Tenant.get/0 directly instead of asking the resolver -> red
    test "a :tenant index asks the field's own strategy" do
      Tenant.put("merchant_other")

      assert Derivation.selector!(card_number_index(), params(tenant: FixedResolver), :dump) ==
               {:tenant, "merchant_7f3"}
    end

    # sabotage: default the resolver to something other than TenantContext.Scope -> red
    test "tenant: :scope reads the process scope through the default resolver" do
      Tenant.put("merchant_7f3")

      assert Derivation.selector!(card_number_index(), params(), :dump) ==
               {:tenant, "merchant_7f3"}
    end

    # sabotage: return :global instead of raising when the resolver errors -> red.
    # A blind-index query that silently matches nothing is the worst failure
    # this feature can have (decision 5).
    test "a missing tenant raises MissingTenantError, never a fallback" do
      error =
        assert_raise MissingTenantError, fn ->
          Derivation.selector!(card_number_index(), params(), :dump)
        end

      assert error.reason == {:blind_index, "card_number_index", :no_tenant_in_scope}
      assert error.table == "payments"
      assert error.column == "card_number"
    end

    # sabotage: replace the resolver reason with a constant in selector!/3 -> red
    test "a resolver's own error reason reaches the exception" do
      error =
        assert_raise MissingTenantError, fn ->
          Derivation.selector!(card_number_index(), params(tenant: RefusingResolver), :dump)
        end

      assert error.reason == {:blind_index, "card_number_index", :no_request_context}
    end

    # sabotage: answer {:ok, _} for a tenant: :none field -> red. Decision
    # 3c makes the pairing a compile error at the declaration; this is the
    # runtime backstop, and it has to name the field as global.
    test "a tenant: :none field cannot key a :tenant index" do
      error =
        assert_raise MissingTenantError, fn ->
          Derivation.selector!(card_number_index(), params(tenant: :none), :dump)
        end

      assert error.reason ==
               {:blind_index, "card_number_index", :field_declared_tenant_none}
    end

    # sabotage: delete the off-contract clause of selector!/3 -> red
    test "an off-contract resolver raises rather than being believed" do
      error =
        assert_raise MissingTenantError, fn ->
          Derivation.selector!(card_number_index(), params(tenant: OffContractResolver), :dump)
        end

      assert error.reason ==
               {:blind_index, "card_number_index", {:resolver_off_contract, OffContractResolver}}
    end

    # sabotage: hard-code :dump in resolve/2 -> red
    test "the operation reaches the resolver" do
      assert Derivation.selector!(card_number_index(), params(tenant: OperationResolver), :load) ==
               {:tenant, "load"}
    end
  end

  describe "the no-leak rule (ADR-0001 decision 6, extended by ADR-0003)" do
    # sabotage: pass `key_material` itself as validate_key_material!/2's
    # refusal reason -> red
    test "the reason names a violated constraint and never a value" do
      derivation = card_number_index()
      key = Derivation.derive(derivation, @key_material)

      error =
        assert_raise DerivationError, fn ->
          Derivation.derive(derivation, binary_part(@other_key_material, 0, 8))
        end

      assert Enum.all?(Tuple.to_list(error.reason), &is_atom/1)

      for rendered <- [Exception.message(error), inspect(error)] do
        refute String.contains?(rendered, @key_material)
        refute String.contains?(rendered, @other_key_material)
        refute String.contains?(rendered, key)
        assert String.contains?(rendered, "card_number_index")
      end
    end

    # sabotage: delete DerivationError's extra_detail/1 override -> red
    test "the exception names the index it could not derive" do
      error =
        assert_raise DerivationError, fn ->
          Derivation.derive(card_number_index(version: 3), <<>>)
        end

      message = Exception.message(error)

      assert String.contains?(message, ~s(index name: "card_number_index"))
      assert String.contains?(message, "index version: 3")
    end
  end
end
