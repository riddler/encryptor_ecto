defmodule Encryptor.Ecto.ScalarTypesRepoTest do
  @moduledoc """
  The six scalar types through the adapter.

  A hand-called `dump/3` proves the callback works. It does not prove that a
  date survives a `bytea` column and comes back a `Date` rather than a string,
  that none of these lands in the natural column type its plaintext suggests,
  or that an absent value reaches the column as `NULL` rather than as an
  encrypted zero. Those are what this file is for.
  """

  use Encryptor.Ecto.RepoCase, async: true

  import Encryptor.Ecto.TenantScope

  alias Ecto.Adapters.SQL
  alias Encryptor.Ecto.DecryptError
  alias Encryptor.Ecto.Tenant
  alias Encryptor.Ecto.TestSchemas.Reading

  @values [
    retry_count: 3,
    fee_rate: 0.0275,
    date_of_birth: ~D[1815-12-10],
    contact_window_opens_at: ~T[09:30:00],
    agreed_at: ~N[2026-09-12 10:20:30],
    verified_at: ~U[2026-09-12 10:20:30Z]
  ]

  defp insert_reading(merchant_id, attrs \\ []) do
    defaults = Keyword.put(@values, :merchant_id, merchant_id)
    TestRepo.insert!(struct(Reading, Keyword.merge(defaults, attrs)))
  end

  defp stored(reading, column) do
    %{rows: [[value]]} =
      SQL.query!(TestRepo, "SELECT #{column} FROM readings WHERE id = $1", [reading.id])

    value
  end

  describe "a schema field naming a scalar type" do
    scope_tenant "merchant_7f3"

    # sabotage: Scalar.dump/5 handing the value to Binary without
    # to_plaintext/2, red - the insert would raise rather than storing bytes.
    test "stores ciphertext and reads the value back as its own type" do
      reading = insert_reading("merchant_7f3")
      loaded = TestRepo.get!(Reading, reading.id)

      for {field, value} <- @values do
        assert is_binary(stored(reading, field))
        assert Map.fetch!(loaded, field) == value
      end
    end

    # The plaintext is textual, so a date's stored bytes could trivially be the
    # date. sabotage: the generated dump/3 returning {:ok, value}, red.
    test "the stored bytes are not the value's textual form" do
      reading = insert_reading("merchant_7f3")

      refute stored(reading, :date_of_birth) == "1815-12-10"
      refute stored(reading, :retry_count) == "3"
    end

    # sabotage: Scalar.dump/5's nil clause deleted, red - nil then falls to
    # to_plaintext/2's catch-all and the insert raises rather than writing the
    # row at all.
    test "leaves an absent value NULL and stores a zero as bytes" do
      absent = insert_reading("merchant_7f3", retry_count: nil)
      zero = insert_reading("merchant_7f3", retry_count: 0)

      assert stored(absent, :retry_count) == nil
      assert byte_size(stored(zero, :retry_count)) > 0

      assert TestRepo.get!(Reading, absent.id).retry_count == nil
      assert TestRepo.get!(Reading, zero.id).retry_count == 0
    end

    # sabotage: the generated equal?/3 comparing dumped values, red - an
    # unchanged field would be marked changed and rewritten under a fresh
    # message on every save.
    test "does not mark an unchanged value changed" do
      reading = insert_reading("merchant_7f3")

      changeset =
        Ecto.Changeset.cast(reading, %{"date_of_birth" => "1815-12-10"}, [:date_of_birth])

      assert changeset.changes == %{}
    end

    # sabotage: Scalar.cast/2 accepting anything, red - the changeset would be
    # valid and the failure would move to the insert.
    test "a changeset refuses a value the primitive would refuse" do
      changeset =
        Ecto.Changeset.cast(%Reading{}, %{"date_of_birth" => "12/09/2026"}, [:date_of_birth])

      refute changeset.valid?
      assert [date_of_birth: {_message, _meta}] = changeset.errors
    end
  end

  describe "the column type" do
    # ADR-0001 decision 2: `:binary`, whatever the plaintext was. The database
    # is the only place that can prove the migration did not reach for the
    # natural type. sabotage: TestMigrationScalars declaring :date for
    # :date_of_birth, red - the insert would be refused by Postgres.
    test "is bytea for every one of them, not the type the plaintext suggests" do
      %{rows: rows} =
        SQL.query!(
          TestRepo,
          """
          SELECT column_name, data_type
          FROM information_schema.columns
          WHERE table_name = 'readings' AND column_name <> 'id'
            AND column_name <> 'merchant_id'
          ORDER BY column_name
          """,
          []
        )

      assert Enum.all?(rows, fn [_name, type] -> type == "bytea" end)
      assert length(rows) == 6
    end
  end

  describe "a row written for another merchant" do
    # sabotage: the generated dump/3 passing params that dropped the tenant,
    # red - the read in the wrong scope would succeed.
    test "does not decrypt its scalars in this merchant's scope" do
      reading = Tenant.wrap("merchant_7f3", fn -> insert_reading("merchant_7f3") end)

      Tenant.wrap("merchant_a19", fn ->
        assert_raise DecryptError, fn -> TestRepo.get!(Reading, reading.id) end
      end)
    end
  end
end
