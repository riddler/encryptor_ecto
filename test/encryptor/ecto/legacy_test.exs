defmodule Encryptor.Ecto.LegacyTest do
  use ExUnit.Case, async: true

  import Encryptor.Ecto.TenantScope

  alias Encryptor.Ecto.Binary
  alias Encryptor.Ecto.DecryptError
  alias Encryptor.Ecto.MissingContextError
  alias Encryptor.Ecto.MissingTenantError
  alias Encryptor.Ecto.SerializationError
  alias Encryptor.Ecto.TestLegacy
  alias Encryptor.Ecto.TestSchemas.Card
  alias Encryptor.Ecto.TestTypes
  alias Encryptor.Ecto.TestVaults

  # The `:legacy` load path of ADR-0004 decision 4, and the telemetry event of
  # decision 5. The legacy format here is a stand-in with no cryptography in
  # it - see `Encryptor.Ecto.TestLegacy` for why that is the right fixture
  # rather than a shortcut.

  # A card number shaped like a real one, and the plaintext every test in this
  # file reads back. No assertion renders it beyond comparing it.
  @pan "4111111111111111"

  defp params(type, field \\ :pan), do: type.init(schema: Card, field: field)

  # Bytes in the old format: what a row the migration has not reached yet
  # holds.
  defp legacy_bytes(value \\ @pan), do: TestLegacy.Format.encode(value)

  # Collects `[:encryptor_ecto, :legacy_load]` into the calling test's mailbox
  # for the duration of that test. The handler id is per-test so that two
  # cases never share one.
  defp capture_legacy_load(context) do
    id = {__MODULE__, context.test, make_ref()}
    owner = self()

    :ok = :telemetry.attach(id, [:encryptor_ecto, :legacy_load], &__MODULE__.forward/4, owner)

    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  # A named function rather than a closure, because `:telemetry` logs an
  # advisory on every local-function handler and the suite's output is worth
  # more than the two lines it saves.
  def forward(event, measurements, metadata, owner) do
    send(owner, {:telemetry, event, measurements, metadata})
  end

  describe "the declaration" do
    # sabotage: init/2 freezing :legacy as nil rather than the validated
    # module, red.
    test "freezes the legacy module into the params, and nil where there is none" do
      assert %{legacy: TestLegacy.Binary} = params(TestTypes.PanLegacy)
      assert %{legacy: nil} = params(TestTypes.Pan)
    end

    # sabotage: validated_legacy!/2's function_exported? condition -> false, red.
    test "refuses a legacy module that cannot read bytes, where it is declared" do
      assert_raise ArgumentError, ~r/does not export load\/1/, fn ->
        Binary.init([vault: TestVaults.Merchant, legacy: TestLegacy.NotAType],
          schema: Card,
          field: :pan
        )
      end
    end

    # sabotage: validated_legacy!/2's Code.ensure_loaded? condition -> false,
    # red - the message then names the missing export rather than the load.
    test "refuses a legacy module that does not exist at all" do
      assert_raise ArgumentError, ~r/could not be loaded/, fn ->
        Binary.init([vault: TestVaults.Merchant, legacy: NoSuchLegacyModule],
          schema: Card,
          field: :pan
        )
      end
    end

    # sabotage: the is_atom guard dropped from validated_legacy!/2's module
    # clause, red (a FunctionClauseError out of Code.ensure_loaded? is not a
    # message a host can act on).
    test "refuses a legacy option that is not a module" do
      assert_raise ArgumentError, ~r/is not a module/, fn ->
        Binary.init([vault: TestVaults.Merchant, legacy: "Payments.Cloak.Binary"],
          schema: Card,
          field: :pan
        )
      end
    end
  end

  describe "the order of the two loads" do
    setup :capture_legacy_load
    scope_tenant "merchant_7f3"

    # sabotage: emit_legacy_load/1 called on load_arm/2's primary arm as
    # well, red - which is the observable shape of the primary being routed
    # through the fallback.
    test "reads a migrated row through the primary, and never asks the legacy" do
      params = params(TestTypes.PanLegacy)

      assert {:ok, ciphertext} = TestTypes.PanLegacy.dump(@pan, nil, params)
      assert {:ok, @pan} = TestTypes.PanLegacy.load(ciphertext, nil, params)

      refute_received {:telemetry, [:encryptor_ecto, :legacy_load], _measurements, _metadata}
    end

    # sabotage: legacy_arm_or_raise!/4's %{legacy: nil} clause matching every
    # params, red.
    test "reads an un-migrated row through the legacy" do
      assert {:ok, @pan} =
               TestTypes.PanLegacy.load(legacy_bytes(), nil, params(TestTypes.PanLegacy))
    end

    # sabotage: unwrap_deferred/1's is_function clause returning the closure
    # rather than calling it, red - the field then holds the function.
    test "invokes a deferred answer once and keeps its result" do
      assert {:ok, @pan} =
               TestTypes.PanLegacyDeferred.load(
                 legacy_bytes(),
                 nil,
                 params(TestTypes.PanLegacyDeferred)
               )
    end

    # sabotage: load/3's nil clause deleted so nil reaches the binary arm, red.
    test "leaves nil alone rather than offering it to either reader" do
      assert TestTypes.PanLegacy.load(nil, nil, params(TestTypes.PanLegacy)) == {:ok, nil}

      refute_received {:telemetry, [:encryptor_ecto, :legacy_load], _measurements, _metadata}
    end

    # sabotage: dump/3's vault call replaced by a passthrough, red. Decision
    # 4c is that dump has no legacy arm at all, so what is assertable is the
    # property it buys: a rewritten row is the new format - unreadable by the
    # legacy reader, readable by the primary.
    test "writes through the new format even for a row that was read through the legacy" do
      params = params(TestTypes.PanLegacy)

      assert {:ok, @pan} = TestTypes.PanLegacy.load(legacy_bytes(), nil, params)
      assert {:ok, rewritten} = TestTypes.PanLegacy.dump(@pan, nil, params)

      assert TestLegacy.Binary.load(rewritten) == :error
      assert {:ok, @pan} = TestTypes.PanLegacy.load(rewritten, nil, params)
    end
  end

  # Decision 4a's two prohibitions. Both fields name
  # `Encryptor.Ecto.TestLegacy.Anything`, which answers every call: against a
  # legacy module that declines, "was never asked" and "was asked and could
  # not answer" are the same observation, and the whole point of the rule is
  # the difference between them.
  describe "a misconfiguration" do
    setup :capture_legacy_load

    # sabotage: resolve_tenant!/2's {:error, _} arm returning :none instead of
    # raising, red - the load then falls through to a legacy reader that
    # answers a host configuration bug with a value.
    test "with no tenant resolved raises rather than reading the legacy bytes" do
      assert_raise MissingTenantError, fn ->
        TestTypes.RefusingLegacy.load(legacy_bytes(), nil, params(TestTypes.RefusingLegacy))
      end

      refute_received {:telemetry, [:encryptor_ecto, :legacy_load], _measurements, _metadata}
    end

    # sabotage: load_arm/2's {:missing_required_context_keys, _} arm removed so
    # the generic arm catches it, red - the legacy reader then answers a
    # configuration bug.
    test "with a required context key missing raises rather than reading the legacy bytes" do
      # Written through the App vault, which requires only the column pair,
      # and read through a field pointed at Strict, which also requires
      # "purpose". Same key material, so what fails is the required set - and
      # it is a well-formed message, so the failure is decision 4a's second
      # prohibition rather than an ordinary refusal of the bytes.
      global = params(TestTypes.Global)
      assert {:ok, ciphertext} = TestTypes.Global.dump(@pan, nil, global)

      error =
        assert_raise MissingContextError, fn ->
          TestTypes.StrictLegacy.load(ciphertext, nil, params(TestTypes.StrictLegacy))
        end

      assert Exception.message(error) =~ "purpose"

      refute_received {:telemetry, [:encryptor_ecto, :legacy_load], _measurements, _metadata}
    end
  end

  describe "when both loads fail" do
    setup :capture_legacy_load
    scope_tenant "merchant_7f3"

    # sabotage: legacy_arm_or_raise!/4's {:error, _} arm raising the legacy
    # reason as the exception's :reason, red.
    test "the primary decrypt error is the one raised" do
      error =
        assert_raise DecryptError, fn ->
          TestTypes.PanLegacy.load(<<0, 1, 2, 3>>, nil, params(TestTypes.PanLegacy))
        end

      assert error.reason == :decrypt_failed

      assert {:legacy_load_also_failed, _engine, {:legacy_declined, TestLegacy.Binary}} =
               error.engine
    end

    # sabotage: legacy_load/2's rescue clause deleted, red - the legacy
    # module's own ArgumentError escapes instead.
    test "a legacy reader that raises does not become the exception a host sees" do
      error =
        assert_raise DecryptError, fn ->
          TestTypes.PanLegacyRaising.load(
            legacy_bytes(),
            nil,
            params(TestTypes.PanLegacyRaising)
          )
        end

      assert {:legacy_load_also_failed, _engine,
              {:legacy_raised, TestLegacy.Raising, ArgumentError}} =
               error.engine
    end

    # sabotage: legacy_load/2's off-contract arm deleted, red (a CaseClauseError
    # is not a DecryptError).
    test "a legacy reader answering off contract is a failed attempt, not a value" do
      error =
        assert_raise DecryptError, fn ->
          TestTypes.PanLegacyOffContract.load(
            legacy_bytes(),
            nil,
            params(TestTypes.PanLegacyOffContract)
          )
        end

      assert {:legacy_load_also_failed, _engine, {:legacy_off_contract, TestLegacy.OffContract}} =
               error.engine
    end

    # sabotage: two mutations together, because either alone is caught by the
    # other - legacy_load/2's rescue carrying Exception.message(exception) and
    # DecryptError.extra_detail/1's Error.redact/1 -> inspect/1, red.
    test "nothing the legacy reader printed reaches the message or the inspect" do
      bytes = legacy_bytes()

      error =
        assert_raise DecryptError, fn ->
          TestTypes.PanLegacyRaising.load(bytes, nil, params(TestTypes.PanLegacyRaising))
        end

      refute Exception.message(error) =~ @pan
      refute Exception.message(error) =~ "choked"
      refute inspect(error) =~ @pan
      refute inspect(error) =~ "choked"
    end

    # sabotage: emit_legacy_load/1 called from legacy_arm_or_raise!/4's
    # {:error, _} arm as well, red.
    test "nothing is counted, because nothing read a legacy row" do
      assert_raise DecryptError, fn ->
        TestTypes.PanLegacy.load(<<0, 1, 2, 3>>, nil, params(TestTypes.PanLegacy))
      end

      refute_received {:telemetry, [:encryptor_ecto, :legacy_load], _measurements, _metadata}
    end
  end

  describe "the legacy_load event" do
    setup :capture_legacy_load
    scope_tenant "merchant_7f3"

    # sabotage: emit_legacy_load/1's body replaced by :ok, red.
    test "counts one, and its metadata is exactly the table and the column" do
      assert {:ok, @pan} =
               TestTypes.PanLegacy.load(legacy_bytes(), nil, params(TestTypes.PanLegacy))

      assert_received {:telemetry, [:encryptor_ecto, :legacy_load], measurements, metadata}
      assert measurements == %{count: 1}
      assert metadata == %{table: "cards", column: "pan"}
    end

    # sabotage: emit_legacy_load/1's metadata hard-coded to one pair, red -
    # the window is per-field and a host with twelve columns has to know which
    # one is still open.
    test "names the field, so the last open window is identifiable" do
      assert {:ok, @pan} =
               TestTypes.PanLegacy.load(legacy_bytes(), nil, params(TestTypes.PanLegacy, :notes))

      assert_received {:telemetry, [:encryptor_ecto, :legacy_load], _measurements, metadata}
      assert metadata == %{table: "cards", column: "notes"}
    end

    # sabotage: emit_legacy_load/1's metadata gaining a third key, red. The
    # set is closed by ADR-0004 decision 5 and widening it is a security
    # review, so the assertion is on the whole map rather than on two members.
    test "carries no value, no bytes, no reason and no tenant" do
      assert {:ok, @pan} =
               TestTypes.PanLegacy.load(legacy_bytes(), nil, params(TestTypes.PanLegacy))

      assert_received {:telemetry, [:encryptor_ecto, :legacy_load], _measurements, metadata}
      assert metadata |> Map.keys() |> Enum.sort() == [:column, :table]
      refute inspect(metadata) =~ @pan
      refute inspect(metadata) =~ "merchant_7f3"
    end
  end

  describe "the types built over Binary" do
    setup :capture_legacy_load
    scope_tenant "merchant_7f3"

    # sabotage: legacy_arm_or_raise!/4's %{legacy: nil} clause matching every
    # params, red - String delegates load wholesale, so the arm it inherits is
    # the only place to break.
    test "String reads an un-migrated row through the legacy, unchecked" do
      assert {:ok, "Ada Lovelace"} =
               TestTypes.HolderNameLegacy.load(
                 legacy_bytes("Ada Lovelace"),
                 nil,
                 params(TestTypes.HolderNameLegacy, :holder_name)
               )
    end

    # sabotage: Map.load/3's {:legacy, loaded} arm routed through decode!/2,
    # red - the serializer then chokes on a map.
    test "Map returns the legacy reader's map without deserializing it again" do
      params = params(TestTypes.MetadataLegacy, :metadata)
      bytes = legacy_bytes(~s({"channel":"web"}))

      assert {:ok, %{"channel" => "web"}} = TestTypes.MetadataLegacy.load(bytes, nil, params)

      assert_received {:telemetry, [:encryptor_ecto, :legacy_load], _measurements, metadata}
      assert metadata == %{table: "cards", column: "metadata"}
    end

    # sabotage: legacy_map!/2's guard dropped so it accepts any term, red.
    test "Map refuses a legacy answer that is not a map, without rendering it" do
      params = params(TestTypes.MetadataLegacyListy, :metadata)

      error =
        assert_raise SerializationError, fn ->
          TestTypes.MetadataLegacyListy.load(legacy_bytes("{}"), nil, params)
        end

      assert error.reason == {:legacy_not_a_map, :list}
      assert error.direction == :decode
      refute Exception.message(error) =~ ~s(["not")
    end

    # sabotage: Map.load/3's primary arm returning the plaintext
    # undeserialized, red.
    test "Map still deserializes what the primary read" do
      params = params(TestTypes.MetadataLegacy, :metadata)

      assert {:ok, ciphertext} = TestTypes.MetadataLegacy.dump(%{"channel" => "web"}, nil, params)
      assert {:ok, %{"channel" => "web"}} = TestTypes.MetadataLegacy.load(ciphertext, nil, params)

      refute_received {:telemetry, [:encryptor_ecto, :legacy_load], _measurements, _metadata}
    end
  end
end
