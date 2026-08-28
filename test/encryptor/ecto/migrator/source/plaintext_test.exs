defmodule Encryptor.Ecto.Migrator.Source.PlaintextTest do
  use ExUnit.Case, async: true

  alias Encryptor.Ecto.Migrator.Source
  alias Encryptor.Ecto.Migrator.Source.Plaintext

  # Sabotage: load/2 returned {:ok, String.reverse(value)} - the backfill leg
  # of an adoption would have written a transformed value.
  test "returns the column's value unchanged" do
    assert Plaintext.load("a note", %{}) == {:ok, "a note"}
  end

  # Sabotage: dropped the nil clause - an empty column raised
  # FunctionClauseError instead of being classified :null.
  test "passes nil through" do
    assert Plaintext.load(nil, %{}) == {:ok, nil}
  end

  # Sabotage: the catch-all clause returned {:ok, value} - a column holding
  # something other than text was re-encrypted as whatever it was.
  test "refuses a value that is neither a binary nor nil" do
    assert Plaintext.load(%{pan: "4111111111111111"}, %{}) == {:error, :not_plaintext}
  end

  # Sabotage: {:error, :not_plaintext} changed to {:error, value}.
  test "the refusal carries no value" do
    assert {:error, reason} = Plaintext.load(%{pan: "4111111111111111"}, %{})

    refute inspect(reason) =~ "4111111111111111"
  end

  # Sabotage: dropped `@behaviour Source` (and its `@impl`) - resolve!/2 saw a
  # module exporting only load/2 and refused it at compile time.
  test "resolves as a source used as-is" do
    assert Source.resolve!(Plaintext, field: :notes) == {Plaintext, %{}}
  end
end
