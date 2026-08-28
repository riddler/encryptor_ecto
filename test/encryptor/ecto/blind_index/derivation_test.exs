defmodule Encryptor.Ecto.BlindIndex.DerivationTest do
  use ExUnit.Case, async: true

  alias Encryptor.Ecto.BlindIndex.Derivation
  alias Encryptor.Ecto.BlindIndex.DerivationError
  alias Encryptor.Ecto.MissingTenantError
  alias Encryptor.Ecto.Tenant
  alias Encryptor.Ecto.TestVaults

  doctest Encryptor.Ecto.BlindIndex.Derivation

  # The vaults these tests derive through hold key material; nothing here does.
  # That is the point of the rework: after enc-ADR-0003 amendment A there is no
  # argument on any function under test that key material could be passed as.
  @merchant_7f3 {:tenant, "merchant_7f3"}
  @merchant_a19 {:tenant, "merchant_a19"}

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

  defp derive!(derivation, selector, vault \\ TestVaults.Merchant) do
    {:ok, key} = Derivation.derive(vault, derivation, selector)
    Base.encode16(key, case: :lower)
  end

  # ADR-0003 decision 2 as amended 2026-08-27 (D1, D2) and reworked onto
  # enc-ADR-0003 amendment A's salted surface on 2026-08-28.
  #
  # Every expected value below was produced by an independent RFC 5869
  # HKDF-SHA256 implementation over extract + two expands, not by running this
  # package or its dependency. That implementation was itself checked against
  # RFC 5869 appendix A.1, A.2 and A.3 first, and every vector was then
  # reproduced a second time through the OpenSSL 3.6 CLI's own HKDF
  # (`openssl kdf ... HKDF` in EXTRACT_AND_EXPAND then EXPAND_ONLY mode), which
  # is the construction upstream locked its own vectors against.
  describe "golden vectors (ADR-0003 d2, amendments 1 and 2, salted 2026-08-28)" do
    # sabotage: change @outer_purpose to "blind_index" -> red
    test "the outer expansion is the reserved encryptor/v1/blind-index label" do
      assert Derivation.outer_label() == "encryptor/v1/blind-index"
    end

    # sabotage: change @info_prefix to "encryptor_ecto/blind_index/v2" -> red
    # sabotage: drop Integer.to_string(version) from info/1 -> red
    test "the info string is decision 2's, with the version D1 added" do
      assert Derivation.info(card_number_index()) ==
               "encryptor_ecto/blind_index/v1|payments|card_number|card_number_index|1"
    end

    # sabotage: change @key_bytes to 16 -> red
    # sabotage: drop `length: @key_bytes` from derive_opts/2 -> red
    test "the derived key is 32 pinned bytes" do
      {:ok, key} = Derivation.derive(TestVaults.Merchant, card_number_index(), @merchant_7f3)

      assert byte_size(key) == 32

      assert Base.encode16(key, case: :lower) ==
               "7ba160ca698ae61a4e4d47de3ace9fa747cf69be459e0a13f1711541c9d19348"
    end

    # sabotage: drop the version component from info/1 -> red. This is the
    # whole point of D1: without it decision 7's rotation rotates nothing.
    test "a version bump derives different bytes" do
      assert derive!(card_number_index(version: 2), @merchant_7f3) ==
               "53644640910582393d04686974cd335403d2d023bea68d48bf43da303fbdc332"

      refute derive!(card_number_index(version: 2), @merchant_7f3) ==
               derive!(card_number_index(), @merchant_7f3)
    end

    # sabotage: drop index_name from info/1 -> red
    test "a second index over one column derives different bytes" do
      assert derive!(card_number_index(index_name: "card_number_truncated"), @merchant_7f3) ==
               "8a76bb1ec3a24844894baa8bbd83e7fe7cf0a31348ab9eefd74e494e87722b3a"
    end

    # sabotage: drop column from info/1, or drop table from it -> red. The
    # table half is the cross-table join decision 2's consequence paragraph
    # promises a host cannot perform against a dump.
    test "a different table or column derives different bytes" do
      assert derive!(
               card_number_index(table: "signups", column: "email", index_name: "email_index"),
               @merchant_7f3
             ) == "13fef6058542758f04fba5d05e51af37b0ba719f26d7a5a9e2f5358dcaa0e3ec"
    end

    # sabotage: hard-code the selector in derive_opts/2 -> red. Two merchants
    # storing one card number must not produce one index value (decision 3b).
    test "a different tenant derives different bytes" do
      assert derive!(card_number_index(), @merchant_a19) ==
               "d480f7acf31d42224d10467ac064147f29bfb21e8abd6398674e4e5841f09e78"

      refute derive!(card_number_index(), @merchant_a19) ==
               derive!(card_number_index(), @merchant_7f3)
    end

    # sabotage: seed the derivation with :crypto.strong_rand_bytes/1 -> red
    test "derivation is deterministic" do
      assert derive!(card_number_index(), @merchant_7f3) ==
               derive!(card_number_index(), @merchant_7f3)
    end
  end

  # enc-ADR-0003 amendment A, implementing the operator's 2026-08-28 ruling:
  # "add the salt now via an upstream HKDF-Extract amendment, shaped to A8's
  # {ikm_selector, salt, info, length}".
  describe "the deployment salt (enc-ADR-0003 amendment A)" do
    defp email_index do
      Derivation.new!(
        table: "signups",
        column: "email",
        index_name: "email_index",
        scope: :global
      )
    end

    # sabotage: give TestVaults.OtherDeployment the same salt as App -> red.
    # This is the whole security value of amendment A: a restored backup or a
    # cloned staging environment derives unrelated index values from identical
    # key material.
    test "two deployments sharing key material derive unrelated keys" do
      assert derive!(email_index(), :global, TestVaults.App) ==
               "a807993c28c0eca20391c5bfbf3ff709d80d0131fe1080e9b7ec20fcba146478"

      assert derive!(email_index(), :global, TestVaults.OtherDeployment) ==
               "656a635504a238da0be4b99ede08457aee12c897e04b280559f4e4b0e7cc0f82"
    end

    # sabotage: make Encryptor.Vault.Derive default a missing salt to "" -> red.
    # A vault deriving under an empty salt would silently produce a key the
    # deployment's own salt was supposed to separate.
    test "a vault with no :derivation_salt refuses to derive" do
      assert {:error, error} =
               Derivation.derive(TestVaults.Unsalted, email_index(), :global)

      assert error.reason == {:missing_config, [:derivation_salt]}
      assert error.operation == :derive
    end

    # sabotage: return the intermediate purpose key instead of running the
    # second expansion -> red. Amendment A decision 4: the second expand always
    # runs, so nothing the package holds internally is ever exported.
    test "the exported bytes are never the intermediate purpose key" do
      {:ok, key} = Derivation.derive(TestVaults.Merchant, card_number_index(), @merchant_7f3)

      refute Base.encode16(key, case: :lower) ==
               "1675e426d1a50b8771e4099c5121f4e10172e19daee86d054fd6681e50305f71"
    end
  end

  describe "derive_opts/2 (A8's scope, minus the salt)" do
    # sabotage: add a `salt:` key to derive_opts/2 -> red. The salt is the
    # vault's per-deployment value and a caller cannot supply one; an option
    # list that could carry one is an option list a call site could get wrong.
    test "never names a salt" do
      opts = Derivation.derive_opts(card_number_index(), @merchant_7f3)

      refute Keyword.has_key?(opts, :salt)
      assert Keyword.fetch!(opts, :length) == 32
      assert Keyword.fetch!(opts, :key) == "merchant_7f3"

      assert Keyword.fetch!(opts, :info) ==
               "encryptor_ecto/blind_index/v1|payments|card_number|card_number_index|1"
    end

    # sabotage: make the :global clause of key_opt/2 emit `key: :default` -> red
    test "a :global index names no key at all" do
      refute Keyword.has_key?(Derivation.derive_opts(email_index(), :global), :key)
    end

    # sabotage: delete key_opt/2's refusing clause -> red. The vault would
    # otherwise answer {:invalid_selector, term} naming a value this package
    # constructed, and that value is a tenant identifier.
    test "refuses a selector that is neither a resolved tenant nor :global" do
      for selector <- [:default, {:tenant, ""}, {:tenant, nil}, "merchant_7f3", nil] do
        error =
          assert_raise DerivationError, fn ->
            Derivation.derive_opts(card_number_index(), selector)
          end

        assert error.reason == {:invalid, :selector, :not_a_selector}
      end
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
    # sabotage: put the selector into key_opt/2's refusal reason -> red
    test "the reason names a violated constraint and never a value" do
      {:ok, key} = Derivation.derive(TestVaults.Merchant, card_number_index(), @merchant_7f3)

      error =
        assert_raise DerivationError, fn ->
          Derivation.derive_opts(card_number_index(), {:tenant, :merchant_7f3})
        end

      assert Enum.all?(Tuple.to_list(error.reason), &is_atom/1)

      for rendered <- [Exception.message(error), inspect(error)] do
        refute String.contains?(rendered, TestVaults.merchant_key("merchant_7f3"))
        refute String.contains?(rendered, TestVaults.derivation_salt())
        refute String.contains?(rendered, key)
        assert String.contains?(rendered, "card_number_index")
      end
    end

    # sabotage: carry the descriptor in Encryptor.Vault.Derive's error -> red.
    # A9's whole claim is that the input key material never reaches a caller,
    # and an error struct a caller can inspect is a way for it to.
    test "a vault refusal carries no key material and no salt" do
      {:error, error} = Derivation.derive(TestVaults.Unsalted, email_index(), :global)

      for rendered <- [Exception.message(error), inspect(error)] do
        refute String.contains?(rendered, TestVaults.merchant_key("merchant_7f3"))
        refute String.contains?(rendered, TestVaults.derivation_salt())
      end
    end

    # sabotage: delete DerivationError's extra_detail/1 override -> red
    test "the exception names the index it could not derive" do
      error =
        assert_raise DerivationError, fn ->
          Derivation.derive_opts(card_number_index(version: 3), :nonsense)
        end

      message = Exception.message(error)

      assert String.contains?(message, ~s(index name: "card_number_index"))
      assert String.contains?(message, "index version: 3")
    end
  end
end
