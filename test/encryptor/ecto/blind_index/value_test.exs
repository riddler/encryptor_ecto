defmodule Encryptor.Ecto.BlindIndex.ValueTest do
  @moduledoc """
  ADR-0003 decision 1, and the `:dump`/`:load` seam
  `Encryptor.Ecto.BlindIndex.Declaration`'s moduledoc rules on.

  The construction itself has its golden vectors in
  `Encryptor.Ecto.BlindIndex.DerivationTest`; what is asserted here is that
  the value is that key's HMAC over the *normalized* plaintext, and that the
  operation the tenant strategy is asked with is the caller's.
  """

  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias Encryptor.Ecto.BlindIndex
  alias Encryptor.Ecto.BlindIndex.Declaration
  alias Encryptor.Ecto.BlindIndex.Derivation
  alias Encryptor.Ecto.BlindIndex.Value
  alias Encryptor.Ecto.Tenant
  alias Encryptor.Ecto.TestSchemas.Capture
  alias Encryptor.Ecto.TestSchemas.Customer
  alias Encryptor.Ecto.TestSchemas.Variant
  alias Encryptor.Ecto.TestVaults

  @merchant "merchant_7f3"

  setup do
    on_exit(&Tenant.clear/0)
    :ok
  end

  describe "compute!/3 is decision 1's construction" do
    # sabotage: `:crypto.mac(:hmac, :sha256, ...)` -> `:crypto.hash(:sha256, ...)`,
    # red - the value becomes the unkeyed folk fingerprint ADR-0003's context
    # exists to argue against, and a dump with no keys at all discloses it.
    test "the value is HMAC-SHA256 of the normalized plaintext under the index key" do
      Tenant.put(@merchant)

      declaration = Declaration.fetch!(Customer, :phone, :phone_index)
      derivation = Declaration.derivation!(declaration)

      {:ok, index_key} =
        Derivation.derive(TestVaults.Merchant, derivation, {:tenant, @merchant})

      assert Value.compute!(declaration, "+1 (555) 0100", :load) ==
               :crypto.mac(:hmac, :sha256, index_key, "15550100")
    end

    # sabotage: `@key_bytes` in Derivation -> 16, red - a shorter key changes
    # nothing about the output width, so this arm is what says a default
    # declaration stores the whole 32 bytes decision 1 stores.
    test "a bits: 256 declaration stores the full 32 bytes" do
      Tenant.put(@merchant)

      full = Declaration.fetch!(Customer, :email, :email_index)

      assert full.bits == 256
      assert byte_size(Value.compute!(full, "bob@example.com", :load)) == 32
    end
  end

  # ADR-0003 decision 6's `:bits`, the half ece-7tk and ece-8cn carried
  # unapplied.
  #
  # The two golden vectors below were produced by an independent RFC 5869
  # HKDF-SHA256 + RFC 2104 HMAC-SHA256 implementation written from the RFCs,
  # not by running this package: extract under the deployment salt, expand
  # under `"encryptor/v1/blind-index"`, expand under this record's `info`, then
  # HMAC the normalized value. That implementation was checked against RFC 5869
  # appendix A.1 first, and against `DerivationTest`'s already-pinned
  # `card_number_index` key as a positive control. Every value was then
  # reproduced a second time through the OpenSSL 3.6 CLI (`openssl kdf ... HKDF`
  # in EXTRACT_ONLY then EXPAND_ONLY mode, then `openssl dgst -sha256 -mac
  # HMAC`).
  describe ":bits truncates the stored value (decision 6)" do
    # sabotage: `binary_part(0, byte_width(declaration))` -> the bare mac, red.
    # This is the vector the operator's crypto read checks: 8 bytes, and
    # *which* 8 - the leading ones, RFC 2104 section 5's "leftmost t bits".
    test "a bits: 64 declaration stores the leading 8 bytes of the HMAC" do
      Tenant.put(@merchant)

      narrow = Declaration.fetch!(Customer, :email, :email_short_index)
      value = Value.compute!(narrow, "bob@example.com", :load)

      assert narrow.bits == 64
      assert byte_size(value) == 8
      assert Base.encode16(value, case: :lower) == "6150b1f20c581920"
    end

    # sabotage: truncate from the end (`binary_part(mac, byte_size(mac) - n, n)`),
    # red here and green on every width assertion, which is exactly why the
    # vector above and this prefix relation are both asserted.
    test "the stored bytes are a prefix of the full-width HMAC under the same key" do
      Tenant.put(@merchant)

      narrow = Declaration.fetch!(Customer, :email, :email_short_index)
      derivation = Declaration.derivation!(narrow)

      {:ok, index_key} =
        Derivation.derive(TestVaults.Merchant, derivation, {:tenant, @merchant})

      full_mac = :crypto.mac(:hmac, :sha256, index_key, "bob@example.com")

      assert Base.encode16(full_mac, case: :lower) ==
               "6150b1f20c58192057850a2de93272f783e1e4dccb34568ee6ddfafebb6efd83"

      assert Value.compute!(narrow, "bob@example.com", :load) == binary_part(full_mac, 0, 8)
    end

    # sabotage: `@key_bytes` in Derivation -> `div(bits, 8)`, i.e. truncating
    # the key instead of the output, red - the whole point of decision 6 is a
    # collision knob on the stored value, and a shortened HMAC key is a
    # weakened HMAC rather than a blurred column.
    test "the index key is the full 32 bytes at every width" do
      Tenant.put(@merchant)

      for column <- [:email_index, :email_short_index] do
        {:ok, key} =
          Customer
          |> Declaration.fetch!(:email, column)
          |> Declaration.derivation!()
          |> then(&Derivation.derive(TestVaults.Merchant, &1, {:tenant, @merchant}))

        assert byte_size(key) == 32
      end
    end

    # sabotage: add `Integer.to_string(bits)` to Derivation.info/1, red - a
    # width change would then also change the key, and decision 7's account of
    # what a `:bits` change invalidates would stop being the whole story.
    test ":bits does not reach the HKDF info string" do
      info =
        Customer
        |> Declaration.fetch!(:email, :email_short_index)
        |> Declaration.derivation!()
        |> Derivation.info()

      assert info == "encryptor_ecto/blind_index/v1|customers|email|email_short_index|1"
      refute info =~ "64"
    end

    # sabotage: `div(bits, 8)` -> `bits`, red - decision 6's widths are bits
    # and the column holds bytes, and eight times the intended width is a
    # `binary_part/3` that raises rather than a value that is merely wrong.
    test "every declared width stores bits / 8 bytes" do
      Tenant.put(@merchant)

      widths =
        for declaration <- Declaration.list(Variant),
            do: {declaration.bits, byte_size(Value.compute!(declaration, "b", :load))}

      assert widths == [{256, 32}, {192, 24}, {128, 16}, {64, 8}]
    end
  end

  describe "which operation an index computation is" do
    # sabotage: put_index/3 asking with `:load`, red - the write side and the
    # read side stop being able to disagree, which is the whole thing this
    # seam exists to let a host express.
    test "a write asks the resolver with :dump and a read asks with :load" do
      write = Value.compute!(capture_declaration(), "abc", :dump)
      read = Value.compute!(capture_declaration(), "abc", :load)

      refute write == read
    end

    # sabotage: put_index/3's `:dump` -> `:load`, red.
    test "put_index/3 writes the :dump answer" do
      changeset =
        %Capture{}
        |> Changeset.cast(%{reference: "abc"}, [:reference])
        |> BlindIndex.put_index(:reference, :reference_index)

      assert Changeset.fetch_change(changeset, :reference_index) ==
               {:ok, Value.compute!(capture_declaration(), "abc", :dump)}
    end

    # sabotage: equality/3's `:load` -> `:dump`, red.
    test "where_eq/3 pins the :load answer" do
      query = BlindIndex.where_eq(Capture, :reference, "abc")

      assert query.wheres |> hd() |> Map.fetch!(:params) |> Enum.map(&elem(&1, 0)) ==
               [Value.compute!(capture_declaration(), "abc", :load)]
    end

    # sabotage: compute/3's `:load` -> `:dump`, red - a host building its own
    # query gets bytes the helper-built query would not have pinned.
    test "compute/3 answers with what a query would pin" do
      assert BlindIndex.compute(Capture, :reference, "abc") ==
               Value.compute!(capture_declaration(), "abc", :load)
    end
  end

  defp capture_declaration, do: Declaration.fetch!(Capture, :reference, :reference_index)
end
