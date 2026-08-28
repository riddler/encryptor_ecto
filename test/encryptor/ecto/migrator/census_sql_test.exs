defmodule Encryptor.Ecto.Migrator.CensusSqlTest do
  @moduledoc """
  The one thing `Encryptor.Ecto.Migrator.CensusTest` cannot ask: does Postgres
  accept it?

  Every assertion in that file reads the rendered text, which is the right way
  to test what the SQL *says* and no way at all to test whether it parses. A
  census module whose whole promise is "paste this into `psql`" and whose
  suite has never handed a line of it to a database is a module whose promise
  nothing checks - so this file executes every query the fixture plans render,
  against the same repository the engine tests use.

  It asserts nothing about the numbers that come back. The rows depend on
  whatever the sandbox holds, and the question here is the one the string
  assertions cannot reach: that the statement runs at all.
  """

  use Encryptor.Ecto.RepoCase, async: false

  alias Ecto.Adapters.SQL
  alias Encryptor.Ecto.Migrator.Census
  alias Encryptor.Ecto.TestEnginePlans

  # Sabotage: dropped the closing paren from the `:progress` query's first
  # `FILTER (...)`. Every string assertion in the sibling file still passed
  # and the operator was handed SQL that does not parse - which is exactly
  # the gap this file exists to close.
  test "every query the fixture plans render is accepted by the database" do
    for plan <- [TestEnginePlans.BothColumns, TestEnginePlans.Adoption, TestEnginePlans.Global],
        query <- Census.queries(plan) do
      assert {:ok, _result} = run(query),
             "#{query.kind} for #{query.table}.#{query.column} did not run"
    end
  end

  # The placeholders are named for an operator reading the query rather than
  # for a driver, so executing one means positioning them first - in the order
  # `:placeholders` lists them, which is what that key is for.
  defp run(query) do
    {sql, _next} =
      Enum.reduce(query.placeholders, {query.sql, 1}, fn placeholder, {sql, index} ->
        {String.replace(sql, ":#{placeholder}", "$#{index}"), index + 1}
      end)

    params = Enum.map(query.placeholders, fn _placeholder -> "x" end)

    SQL.query(TestRepo, sql, params)
  end
end
