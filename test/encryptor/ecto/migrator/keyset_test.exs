defmodule Encryptor.Ecto.Migrator.KeysetTest do
  @moduledoc """
  Which primary keys the founding implementation pages over, and which it
  refuses (ADR-0002 proposed amendment 4, answering Q6 with the operator's
  ruling: integer and binary primary keys day one, composite
  documented-unsupported until asked for).
  """

  use ExUnit.Case, async: true

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias Encryptor.Ecto.Migrator.Keyset
  alias Encryptor.Ecto.TestRepo
  alias Encryptor.Ecto.TestSchemas

  doctest Encryptor.Ecto.Migrator.Keyset, import: true

  describe "primary_key/1" do
    # Sabotage: removed `:id` from the orderable map - the ordinary
    # bigserial-keyed schema, which is nearly every schema, was refused.
    test "an integer key is ordered day one" do
      assert {:ok, {:id, :integer}} = Keyset.primary_key(TestSchemas.Card)
    end

    # Sabotage: removed `:binary_id` - a UUID-keyed schema was refused, though
    # it orders correctly and only scatters over the index.
    test "a binary_id key is ordered day one" do
      assert {:ok, {:id, :binary_id}} = Keyset.primary_key(TestSchemas.Reference)
    end

    # Sabotage: made the multi-column clause take the first column - a
    # composite-key table was paged over half its key, which skips rows.
    test "a composite key is refused, naming the schema and the columns" do
      assert {:error, message} = Keyset.primary_key(TestSchemas.Composite)
      assert message =~ "Composite"
      assert message =~ "[:merchant_id, :sequence]"
    end

    # Sabotage: added `:string` to the orderable map - a text key was paged
    # over an order that depends on the database's collation.
    test "a key of an unordered type is refused, naming the type" do
      assert {:error, message} = Keyset.primary_key(TestSchemas.Coded)
      assert message =~ ":code"
      assert message =~ ":string"
    end
  end

  describe "primary_key/1 on a schema with none" do
    # Sabotage: made the `[]` clause fall through to the composite message - a
    # schema with no primary key was reported as having a composite one.
    test "is refused, naming the schema" do
      assert {:error, message} = Keyset.primary_key(TestSchemas.Unkeyed)
      assert message =~ "Unkeyed"
      assert message =~ "declares no primary key"
    end
  end

  describe "the queries, per key type" do
    # Rendering a query to SQL asks the adapter, so these need the repository
    # started even though they open no transaction and touch no row.
    @describetag :database

    # Sabotage: made every `after_cursor/4` clause compare at `:integer` - the
    # UUID and binary keys were compared at the wrong type, which Postgres
    # refuses rather than answering wrongly, on row `batch_size + 1`.
    test "each key type compares the cursor at its own type" do
      for {type, cursor} <- [
            {:integer, 10},
            {:binary_id, Ecto.UUID.generate()},
            {:binary, <<1, 2, 3>>}
          ] do
        query = Keyset.batch_query("cards", {:id, type}, :pan, :pan, :merchant_id, cursor, 5)
        {sql, params} = SQL.to_sql(:all, TestRepo, query)

        assert sql =~ ~s{"id" > $1}
        assert sql =~ "ORDER BY"
        assert sql =~ "LIMIT"
        assert [param | _rest] = params
        refute param == nil
      end
    end

    # Sabotage: made `at_id/4`'s binary clauses compare at `:integer` - the
    # compare-and-swap for a binary-keyed row could not be built at all.
    test "the swap names the row at its own key type" do
      for {type, id} <- [
            {:integer, 10},
            {:binary_id, Ecto.UUID.generate()},
            {:binary, <<1, 2, 3>>}
          ] do
        # A swap query carries no select of its own - it is built for
        # `update_all` - so one is added here to render it.
        query = Keyset.swap_query("cards", {:id, type}, id, :pan, <<9>>)
        {sql, _params} = SQL.to_sql(:all, TestRepo, from(r in query, select: 1))

        assert sql =~ ~s{"id" = $1}
        assert sql =~ ~s{"pan" = $2}
      end
    end

    # Sabotage: dropped `row_query/4`'s select - the re-probe read the whole
    # row through the schema's own types, which decrypts the column the
    # migrator is here to rewrite.
    test "the re-probe reads one column of one row" do
      query = Keyset.row_query("cards", {:id, :integer}, 1, :pan)
      {sql, _params} = SQL.to_sql(:all, TestRepo, query)

      assert sql =~ ~s{SELECT c0."pan"}
    end
  end

  describe "source/1" do
    # Sabotage: returned the schema module rather than its source - every
    # query named a table that does not exist.
    test "is the schema's table" do
      assert Keyset.source(TestSchemas.Card) == "cards"
    end
  end
end
