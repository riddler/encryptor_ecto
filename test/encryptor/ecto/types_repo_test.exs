defmodule Encryptor.Ecto.TypesRepoTest do
  @moduledoc """
  `Encryptor.Ecto.String` and `Encryptor.Ecto.Map` through the adapter.

  A hand-called `dump/3` proves the callback works. It does not prove that a
  serialized map survives a `bytea` column and comes back as a map, that a text
  field lands in `:binary` rather than needing a `:text` column, or that `nil`
  reaches the column as `NULL` rather than as an encrypted empty map. Those are
  what this file is for.
  """

  use Encryptor.Ecto.RepoCase, async: true

  import Encryptor.Ecto.TenantScope

  alias Ecto.Adapters.SQL
  alias Encryptor.Ecto.DecryptError
  alias Encryptor.Ecto.Tenant
  alias Encryptor.Ecto.TestSchemas.Card

  @name "Ada Lovelace"
  @metadata %{"channel" => "web", "avs_result" => "Y"}

  defp insert_card(merchant_id, attrs \\ []) do
    defaults = [merchant_id: merchant_id, holder_name: @name, metadata: @metadata]
    TestRepo.insert!(struct(Card, Keyword.merge(defaults, attrs)))
  end

  describe "a schema field naming the map type" do
    scope_tenant "merchant_7f3"

    # sabotage: Map.dump/3 handing the map to Binary without encoding, red -
    # the insert would raise instead of storing bytes.
    test "stores ciphertext and reads back a map with string keys" do
      card = insert_card("merchant_7f3")

      %{rows: [[stored]]} =
        SQL.query!(TestRepo, "SELECT metadata FROM cards WHERE id = $1", [card.id])

      refute stored =~ "channel"

      assert TestRepo.get!(Card, card.id).metadata == @metadata
    end

    # sabotage: Map.load/3's decode step removed, red - the read would give
    # back a JSON binary rather than a map.
    test "a map written with atom keys reads back with string keys" do
      card = insert_card("merchant_7f3", metadata: %{channel: "pos"})

      assert TestRepo.get!(Card, card.id).metadata == %{"channel" => "pos"}
    end

    # sabotage: Map.dump/3's nil clause deleted, red - nil then fails the
    # is_map guard and falls to refuse_non_map!/2, so the insert raises rather
    # than writing the row at all.
    test "leaves an absent map NULL, and stores an empty one as bytes" do
      absent = insert_card("merchant_7f3", metadata: nil)
      empty = insert_card("merchant_7f3", metadata: %{})

      %{rows: [[stored_absent]]} =
        SQL.query!(TestRepo, "SELECT metadata FROM cards WHERE id = $1", [absent.id])

      %{rows: [[stored_empty]]} =
        SQL.query!(TestRepo, "SELECT metadata FROM cards WHERE id = $1", [empty.id])

      assert stored_absent == nil
      assert byte_size(stored_empty) > 0

      assert TestRepo.get!(Card, absent.id).metadata == nil
      assert TestRepo.get!(Card, empty.id).metadata == %{}
    end

    # sabotage: Map.equal?/3 comparing dumped values, red - an unchanged field
    # would be marked changed and rewritten under a fresh message every save.
    test "does not mark an unchanged map changed" do
      card = insert_card("merchant_7f3")

      changeset = Ecto.Changeset.cast(card, %{"metadata" => @metadata}, [:metadata])
      assert changeset.changes == %{}
    end
  end

  describe "a schema field naming the string type" do
    scope_tenant "merchant_7f3"

    # sabotage: String's generated dump/3 returning {:ok, value}, red.
    test "stores ciphertext in a binary column and reads back text" do
      card = insert_card("merchant_7f3")

      %{rows: [[stored]]} =
        SQL.query!(TestRepo, "SELECT holder_name FROM cards WHERE id = $1", [card.id])

      refute stored == @name
      assert byte_size(stored) > byte_size(@name)

      assert TestRepo.get!(Card, card.id).holder_name == @name
    end

    # sabotage: String.cast/2's String.valid?/1 branch -> {:ok, value}, red -
    # the changeset would be valid.
    test "a changeset refuses bytes that are not valid UTF-8" do
      changeset = Ecto.Changeset.cast(%Card{}, %{"holder_name" => <<0xFF, 0xFE>>}, [:holder_name])

      refute changeset.valid?
      assert [holder_name: {_message, _meta}] = changeset.errors
    end
  end

  describe "a row written for another merchant" do
    # sabotage: Map.dump/3 passing params that dropped the tenant, red - the
    # read in the wrong scope would succeed.
    test "does not decrypt its map in this merchant's scope" do
      card = Tenant.wrap("merchant_7f3", fn -> insert_card("merchant_7f3") end)

      Tenant.wrap("merchant_a19", fn ->
        assert_raise DecryptError, fn -> TestRepo.get!(Card, card.id) end
      end)
    end
  end
end
