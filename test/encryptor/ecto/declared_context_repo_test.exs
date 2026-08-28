defmodule Encryptor.Ecto.DeclaredContextRepoTest do
  @moduledoc """
  The declared context through the adapter.

  A hand-called `init/1` proves the pin is read. It does not prove that Ecto
  carries a field-level option into `init/1` at all, nor that the pinned value
  is what the bytes in the column are actually authenticated under - which is
  the claim acceptance amendment 5 rests on, and the only one that decides
  whether a physical rename is free or fleet-wide.
  """

  use Encryptor.Ecto.RepoCase, async: true

  import Encryptor.Ecto.TenantScope

  alias Ecto.Adapters.SQL
  alias Encryptor.Ecto.DecryptError
  alias Encryptor.Ecto.TestSchemas.Card

  @pan "4111111111111111"

  defmodule Pinned do
    @moduledoc """
    The same physical column as `TestSchemas.Card`, declaring a different
    context. Standing in for a schema whose column was renamed under it: the
    physical location moved, the declared pair did not.
    """

    use Ecto.Schema

    @type t :: %__MODULE__{}

    schema "cards" do
      field(:merchant_id, :string)
      field(:pan, Encryptor.Ecto.TestTypes.Pan, table: "card_archive", column: "pan_2024")
    end
  end

  describe "a field whose declared context is pinned" do
    scope_tenant "merchant_7f3"

    # sabotage: Binary.declared_value/4's field-level pin lookup deleted, red -
    # the pin would be ignored and the row would round-trip through Card,
    # which is the silent failure the freeze exists to prevent.
    test "round-trips through the repository under the pinned pair" do
      card = TestRepo.insert!(%Pinned{merchant_id: "merchant_7f3", pan: @pan})

      %{rows: [[stored]]} =
        SQL.query!(TestRepo, "SELECT pan FROM cards WHERE id = $1", [card.id])

      refute stored == @pan
      assert TestRepo.get!(Pinned, card.id).pan == @pan
    end

    # sabotage: Binary.encryption_context/1 built from the derived values
    # rather than the frozen ones, red - both schemas would read the row.
    test "is not readable by a schema declaring the derived pair" do
      card = TestRepo.insert!(%Pinned{merchant_id: "merchant_7f3", pan: @pan})

      assert_raise DecryptError, fn -> TestRepo.get!(Card, card.id) end
    end

    # sabotage: the same, from the other side.
    test "cannot read a row the derived pair wrote" do
      card = TestRepo.insert!(%Card{merchant_id: "merchant_7f3", pan: @pan})

      assert_raise DecryptError, fn -> TestRepo.get!(Pinned, card.id) end
    end
  end
end
