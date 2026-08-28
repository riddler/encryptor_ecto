defmodule Encryptor.Ecto.BinaryRepoTest do
  @moduledoc """
  The type through the adapter, which is the only place several of its claims
  are actually testable.

  A hand-called `dump/3` proves the callback works. It does not prove that
  Ecto calls it, that a `:binary` return survives a `bytea` column, that `nil`
  reaches the column as `NULL` rather than as encrypted bytes, or that a read
  in the wrong tenant's scope fails at the point a host would meet it. Those
  are what this file is for.
  """

  use Encryptor.Ecto.RepoCase, async: true

  import Encryptor.Ecto.TenantScope

  alias Ecto.Adapters.SQL
  alias Encryptor.Ecto.DecryptError
  alias Encryptor.Ecto.MissingTenantError
  alias Encryptor.Ecto.Tenant
  alias Encryptor.Ecto.TestSchemas.Card

  @pan "4111111111111111"
  @notes "signature on file"

  defp insert_card(merchant_id, attrs \\ []) do
    TestRepo.insert!(struct(Card, Keyword.merge([merchant_id: merchant_id, pan: @pan], attrs)))
  end

  describe "a schema field naming the type" do
    scope_tenant "merchant_7f3"

    # sabotage: Binary.dump/3's is_binary arm returning {:ok, value}, red -
    # the stored bytes would equal the plaintext.
    test "stores ciphertext and reads back plaintext" do
      card = insert_card("merchant_7f3", notes: @notes)

      %{rows: [[stored_pan]]} =
        SQL.query!(TestRepo, "SELECT pan FROM cards WHERE id = $1", [card.id])

      refute stored_pan == @pan
      assert byte_size(stored_pan) > byte_size(@pan)

      read_back = TestRepo.get!(Card, card.id)
      assert read_back.pan == @pan
      assert read_back.notes == @notes
      assert read_back.merchant_id == "merchant_7f3"
    end

    # sabotage: Binary.dump/3's nil clause deleted, red - the column would
    # hold bytes instead of NULL.
    test "leaves an absent value NULL in the column" do
      card = insert_card("merchant_7f3", pan: nil)

      %{rows: [[stored_pan]]} =
        SQL.query!(TestRepo, "SELECT pan FROM cards WHERE id = $1", [card.id])

      assert stored_pan == nil
      assert TestRepo.get!(Card, card.id).pan == nil
    end

    # sabotage: Binary.equal?/3 comparing dumped values, red - an unchanged
    # field would be marked changed and rewritten.
    test "does not mark an unchanged field changed" do
      card = insert_card("merchant_7f3")

      changeset = Ecto.Changeset.cast(card, %{"pan" => @pan}, [:pan])
      assert changeset.changes == %{}
    end
  end

  describe "a row written for another merchant" do
    # sabotage: Binary's encryption_context/1 dropping a pair would not show
    # here, but vault_opts/2 ignoring the tenant would: red, the read would
    # succeed.
    test "does not decrypt in this merchant's scope" do
      card = Tenant.wrap("merchant_7f3", fn -> insert_card("merchant_7f3") end)

      Tenant.wrap("merchant_a19", fn ->
        assert_raise DecryptError, fn -> TestRepo.get!(Card, card.id) end
      end)
    end
  end

  describe "a write with no tenant in scope" do
    # sabotage: resolve_tenant!/2's {:error, _} arm returning a default
    # tenant, red - the insert would succeed and the row would be
    # unrecoverable.
    test "raises rather than writing the row" do
      Tenant.clear()

      assert_raise MissingTenantError, fn -> insert_card("merchant_7f3") end

      %{rows: [[count]]} = SQL.query!(TestRepo, "SELECT count(*) FROM cards", [])
      assert count == 0
    end
  end
end
