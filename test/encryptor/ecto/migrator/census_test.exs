defmodule Encryptor.Ecto.Migrator.CensusTest do
  @moduledoc """
  The rendered SQL, and the properties that make it worth shipping.

  Nothing here connects to a database, which is the point of the module under
  test: these queries are for someone who has a `psql` prompt and no
  application. What the tests hold onto is the small set of things the SQL has
  to get right - the wider prefix, the columns it names, and the queries it
  declines to render.
  """

  use ExUnit.Case, async: true

  alias Encryptor.Ecto.Migrator.Census
  alias Encryptor.Ecto.TestEnginePlans
  alias Encryptor.Ecto.TestSchemas

  describe "the format census" do
    # Sabotage: made `header_bytes/0` answer 1. The rendered census then
    # grouped on the first byte alone, which cloak's reserved `0x01` and this
    # package's version byte can share - a half-legacy table reads as one
    # format, which is the exact trap ADR-0004 decision 11 records.
    test "groups on a prefix wider than one byte" do
      assert Census.header_bytes() > 1

      sql = sql_for(TestEnginePlans.Cards, :format)
      assert sql =~ "substring(\"pan\" from 1 for #{Census.header_bytes()})"
    end

    # Sabotage: made `format/1` render `WHERE substring(...) = :current_header`
    # rather than `GROUP BY` - the census answered "how many are ours?" with a
    # prefix the operator had to already know, instead of printing every
    # format present and letting them read which one is growing.
    test "prints every prefix present rather than testing for one" do
      sql = sql_for(TestEnginePlans.Cards, :format)

      assert sql =~ "GROUP BY 1"
      assert sql =~ "count(*) AS rows"
      assert sql =~ "IS NOT NULL"
      refute sql =~ ":current_header"
    end
  end

  describe "rotation progress" do
    # Sabotage: dropped `progress/2`'s tenant `WHERE` - the per-tenant
    # progress query counted the whole table, so an operator watching one
    # tenant's rotation read every other tenant's rows as their own progress.
    test "filters on the rewrite's own tenant column" do
      query = query_for(TestEnginePlans.Cards, :progress)

      assert query.sql =~ ~s(WHERE "merchant_id" = :tenant)
      assert query.placeholders == [:current_header, :tenant]
    end

    # Sabotage: made `progress/2`'s fallback clause render the query with no
    # `WHERE` - a plan with no tenant column produced a whole-table count
    # wearing a tenant's name.
    test "is not rendered for a rewrite with no tenant column" do
      kinds = TestEnginePlans.Global |> Census.queries() |> Enum.map(& &1.kind)

      assert :format in kinds
      assert :integrity in kinds
      refute :progress in kinds
    end
  end

  describe "the integrity count" do
    # Sabotage: made `integrity/2` drop the `octet_length(...) = 0` count -
    # the before/after comparison caught a row that became NULL and missed one
    # that became an empty string, which is the same lost value with a
    # different shape.
    test "counts rows, non-NULL and empty over the one column" do
      sql = sql_for(TestEnginePlans.Cards, :integrity)

      assert sql =~ "count(*) AS rows"
      assert sql =~ ~s[count("pan") AS non_null]
      assert sql =~ ~s[count(*) FILTER (WHERE octet_length("pan") = 0) AS empty]
    end

    # Sabotage: made `rewrite_queries/2` ignore `into:` - every query named
    # the plaintext column the backfill reads rather than the binary one it
    # writes, so the census reported on the wrong column of an adoption
    # migration entirely.
    test "an into: rewrite counts both columns, and the census reads the target" do
      queries = Census.queries(TestEnginePlans.Adoption)

      assert Enum.all?(queries, &(&1.column == "email_encrypted"))

      sql = sql_for(TestEnginePlans.Adoption, :integrity)
      assert sql =~ ~s[count("email") AS source_non_null]
      assert sql =~ ~s[count("email_encrypted") AS target_non_null]
    end
  end

  describe "naming the tables" do
    # Sabotage: rendered the table name bare instead of through `quoted/1` -
    # a table or column named for a reserved word produced SQL the operator
    # had to repair by hand before it would run.
    test "quotes every identifier" do
      sql = sql_for(TestEnginePlans.Cards, :format)

      assert sql =~ ~s(FROM "cards")
      assert sql =~ ~s("pan")
    end

    # Sabotage: made `table/2` ignore the prefix - the census read the default
    # prefix's rows while the operator believed they were watching another
    # one, which is the same defect `verify/2`'s `prefix:` exists to prevent.
    test "prefix: puts the tables in that schema" do
      sql = sql_for(TestEnginePlans.Cards, :format, prefix: "tenant_b")
      assert sql =~ ~s(FROM "tenant_b"."cards")
    end
  end

  describe "queries/2 and script/1" do
    # Sabotage: made `rewrite_queries/2` render only the first field - the
    # second encrypted column of a schema had no census at all, and a host
    # reading a green one for `pan` had no signal about `notes`.
    test "renders every field of every rewrite" do
      fields =
        TestEnginePlans.BothColumns
        |> Census.queries()
        |> Enum.map(& &1.field)
        |> Enum.uniq()

      assert fields == [:pan, :notes]
    end

    # Sabotage: made `script/1` join the SQL with no comment line - the
    # operator was handed nine anonymous queries and had to read each one to
    # find out which question it answered.
    test "script/1 puts a heading over each query" do
      script = TestEnginePlans.Cards |> Census.queries() |> Census.script()

      assert script =~ "-- \"cards\".\"pan\": format census"
      assert script =~ "-- \"cards\".\"pan\": rotation progress for one tenant"
      assert script =~ "-- \"cards\".\"pan\": nothing became NULL or empty"
    end

    # Sabotage: had `queries/2` call `Plan.fetch!/2` with `run/2`'s name - a
    # schema module handed to the census sent the reader to a function they
    # had not called.
    test "a module that is not a plan is refused, naming the census" do
      error = assert_raise ArgumentError, fn -> Census.queries(TestSchemas.Card) end

      assert error.message =~ "Census.queries/2"
      assert error.message =~ "expects a plan module"
    end
  end

  defp query_for(plan, kind, opts \\ []) do
    plan |> Census.queries(opts) |> Enum.find(&(&1.kind == kind))
  end

  defp sql_for(plan, kind, opts \\ []), do: query_for(plan, kind, opts).sql
end
