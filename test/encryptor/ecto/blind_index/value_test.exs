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
    # nothing about the output width, so this arm is what says the stored
    # value is the whole 32 bytes decision 1 stores (`:bits` truncation is
    # decision 6's option half and is not applied here).
    test "the value is the full 32 bytes, whatever :bits the declaration carries" do
      Tenant.put(@merchant)

      full = Declaration.fetch!(Customer, :email, :email_index)
      narrow = Declaration.fetch!(Customer, :email, :email_short_index)

      assert narrow.bits == 64
      assert byte_size(Value.compute!(full, "bob@example.com", :load)) == 32
      assert byte_size(Value.compute!(narrow, "bob@example.com", :load)) == 32
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
