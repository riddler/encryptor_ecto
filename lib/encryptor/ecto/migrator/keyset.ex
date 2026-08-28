defmodule Encryptor.Ecto.Migrator.Keyset do
  @moduledoc """
  Keyset pagination over one schema's table, below the schema layer.

  ADR-0002 decision 6: rows are visited in primary-key order with
  `where: r.id > ^cursor`, `order_by: r.id`, `limit: ^batch_size`, never
  `OFFSET`, which degrades quadratically and skips rows when the set shifts
  under it.

  ## Why the queries are schemaless

  ADR-0002 decision 3 puts the migrator below the schema layer: it reads the
  **raw** bytes of the ciphertext columns and calls the type modules itself,
  with params it constructs. A query built on the schema module would run
  every encrypted field through its own `load/3` on the way out - which is to
  say it would decrypt the column the migrator is here to re-encrypt, under
  whatever tenant happened to be in scope, and raise before the pass ever
  reached its own probe. So the queries here name the table's **source**
  string, and what comes back is what the adapter returned.

  ## Which primary keys are ordered, and which are refused

  ADR-0002 proposed amendment 4, answering Q6 with the operator's ruling
  *integer/binary PKs day one, composite documented-unsupported until asked
  for*: a single-column primary key of an integer or a binary type is ordered
  day one, because both are a total order every supported adapter expresses as
  one `>` comparison on one column, and the binary case covers UUID keys
  stored as `:binary_id`.

  A composite primary key, or a single column of a type with no such order, is
  **refused with a clear error naming the schema and its primary key** rather
  than paged over under a guess. There is deliberately no `order_by:` escape
  hatch: reopening this is additive when a real host arrives with a
  composite-key table.

  The cursor is the primary key as the adapter returned it, and it is compared
  with the same type it was read at - which is why the type travels beside it
  everywhere in this module rather than being re-derived from the value's
  shape.
  """

  import Ecto.Query, only: [from: 2]

  @typedoc """
  The primary key of a schema the migrator can page over: its column and the
  Ecto type its comparisons are made at.
  """
  @type key :: {atom(), :integer | :binary_id | :binary}

  # The Ecto primary-key types this pagination is defined for, mapped to the
  # type each comparison is made at. `:id` and `:integer` are the integer
  # case; `:binary_id` is a UUID key, which orders correctly and scatters over
  # the index - a cost in read locality, not a correctness problem.
  @orderable %{
    id: :integer,
    integer: :integer,
    binary_id: :binary_id,
    binary: :binary
  }

  @doc """
  The primary key the pass pages over, or the reason it cannot.

      iex> alias Encryptor.Ecto.Migrator.Keyset
      iex> Keyset.primary_key(Encryptor.Ecto.TestSchemas.Card)
      {:ok, {:id, :integer}}
  """
  @spec primary_key(module()) :: {:ok, key()} | {:error, String.t()}
  def primary_key(schema) do
    case schema.__schema__(:primary_key) do
      [column] -> single_column_key(schema, column)
      [] -> {:error, no_primary_key_message(schema)}
      columns -> {:error, composite_key_message(schema, columns)}
    end
  end

  @doc """
  The table the rewrite reads and writes, prefix included where one was given.
  """
  @spec source(module()) :: String.t()
  def source(schema), do: schema.__schema__(:source)

  @doc """
  One batch of rows, as `[primary_key, source_value, target_value]` lists.

  `tenant_column` is the column a `tenant_from` rewrite reads the tenant off,
  and `nil` for a rewrite whose tenant is `:none` or a resolver module; where
  it is given, the tenant is appended to each row.

  `source_column` and `target_column` are the same column for an ordinary
  rewrite and different ones for the backfill leg of an adoption migration
  (`into:`), which is why both are selected even when they coincide.
  """
  @spec batch_query(String.t(), key(), atom(), atom(), atom() | nil, term(), pos_integer()) ::
          Ecto.Query.t()
  def batch_query(source, key, source_column, target_column, tenant_column, cursor, size) do
    {column, type} = key

    source
    |> base_query(column, size)
    |> after_cursor(column, type, cursor)
    |> select_row(column, source_column, target_column, tenant_column)
  end

  @doc """
  One random sample of rows, in the same shape `batch_query/7` returns.

  ADR-0002 decision 10's `sample:` option. The rows are drawn in **random**
  order rather than as the first `size` rows in key order, and the reason is
  the whole value of the option: key order is the order the pass writes in, so
  a prefix of it is precisely the region a partial or resumed pass migrated
  first. A sampled verification over that prefix would report every row
  `:already_target` while the tail of the table was untouched - a verification
  that is wrong in the one direction a verification must not be wrong in.

  The cost is an ordering over the scope, which is why `sample:` is a drift
  detector a host runs on a schedule and `sample: :all` - the keyset scan
  `batch_query/7` performs - is the acceptance test at the end of a rotation
  (ADR-0004 decision 8, step 6).

  `random()` is spelled that way by PostgreSQL and SQLite; MySQL spells it
  `rand()`. That is the same adapter assumption ADR-0002 decision 10's census
  SQL already makes, and it is confined to this one clause.
  """
  @spec sample_query(String.t(), key(), atom(), atom(), atom() | nil, pos_integer()) ::
          Ecto.Query.t()
  def sample_query(source, {column, _type}, source_column, target_column, tenant_column, size) do
    query = from(r in source, order_by: fragment("random()"), limit: ^size)
    select_row(query, column, source_column, target_column, tenant_column)
  end

  @doc """
  The compare-and-swap update for one row (ADR-0002 decision 4).

  The update is conditional on the target column still holding the exact bytes
  the migrator read. Zero rows affected means the application wrote the row
  while the migrator was working on it, which is not an error and is not a
  clobber: the row is re-probed and counted.
  """
  @spec swap_query(String.t(), key(), term(), atom(), binary() | nil) :: Ecto.Query.t()
  def swap_query(source, {column, type}, id, target_column, previous) do
    source
    |> at_id(column, type, id)
    |> unchanged(target_column, previous)
  end

  @doc """
  Re-reads one row's target column, for the re-probe after a lost swap.
  """
  @spec row_query(String.t(), key(), term(), atom()) :: Ecto.Query.t()
  def row_query(source, {column, type}, id, target_column) do
    source
    |> at_id(column, type, id)
    |> then(fn query -> from(r in query, select: [field(r, ^target_column)]) end)
  end

  @doc """
  Restricts a query to the tenants a run named (ADR-0002 decision 11).

  The filter is a `where` on the tenant column rather than a decision made per
  row: a crypto-shredded tenant's rows are permanently undecryptable by
  design, and the point of the filter is that the pass never visits them and
  still exits zero.
  """
  @spec tenant_filter(Ecto.Query.t(), atom(), [String.t()] | nil, [String.t()]) :: Ecto.Query.t()
  def tenant_filter(query, column, only, except) do
    query
    |> only_tenants(column, only)
    |> except_tenants(column, except)
  end

  @spec single_column_key(module(), atom()) :: {:ok, key()} | {:error, String.t()}
  defp single_column_key(schema, column) do
    case Map.fetch(@orderable, schema.__schema__(:type, column)) do
      {:ok, type} -> {:ok, {column, type}}
      :error -> {:error, unorderable_key_message(schema, column)}
    end
  end

  @spec base_query(String.t(), atom(), pos_integer()) :: Ecto.Query.t()
  defp base_query(source, column, size) do
    from(r in source, order_by: [asc: field(r, ^column)], limit: ^size)
  end

  # The cursor comparison is written out once per key type rather than through
  # an interpolated `type/2`, so the comparison a given key is paged with is
  # readable in the source rather than assembled at run time.
  @spec after_cursor(Ecto.Query.t(), atom(), atom(), term()) :: Ecto.Query.t()
  defp after_cursor(query, _column, _type, nil), do: query

  defp after_cursor(query, column, :integer, cursor),
    do: from(r in query, where: field(r, ^column) > type(^cursor, :integer))

  defp after_cursor(query, column, :binary_id, cursor),
    do: from(r in query, where: field(r, ^column) > type(^cursor, :binary_id))

  defp after_cursor(query, column, :binary, cursor),
    do: from(r in query, where: field(r, ^column) > type(^cursor, :binary))

  @spec at_id(String.t(), atom(), atom(), term()) :: Ecto.Query.t()
  defp at_id(source, column, :integer, id),
    do: from(r in source, where: field(r, ^column) == type(^id, :integer))

  defp at_id(source, column, :binary_id, id),
    do: from(r in source, where: field(r, ^column) == type(^id, :binary_id))

  defp at_id(source, column, :binary, id),
    do: from(r in source, where: field(r, ^column) == type(^id, :binary))

  # `NULL = NULL` is not true in SQL, so the "still empty" half of a
  # compare-and-swap over the backfill leg has to be written as `IS NULL`.
  # Getting this wrong is a swap that never matches and a pass that reports
  # every row as concurrently migrated.
  @spec unchanged(Ecto.Query.t(), atom(), binary() | nil) :: Ecto.Query.t()
  defp unchanged(query, target_column, nil),
    do: from(r in query, where: is_nil(field(r, ^target_column)))

  defp unchanged(query, target_column, previous),
    do: from(r in query, where: field(r, ^target_column) == type(^previous, :binary))

  @spec select_row(Ecto.Query.t(), atom(), atom(), atom(), atom() | nil) :: Ecto.Query.t()
  defp select_row(query, key_column, source_column, target_column, nil) do
    from(r in query,
      select: [field(r, ^key_column), field(r, ^source_column), field(r, ^target_column)]
    )
  end

  defp select_row(query, key_column, source_column, target_column, tenant_column) do
    from(r in query,
      select: [
        field(r, ^key_column),
        field(r, ^source_column),
        field(r, ^target_column),
        field(r, ^tenant_column)
      ]
    )
  end

  @spec only_tenants(Ecto.Query.t(), atom(), [String.t()] | nil) :: Ecto.Query.t()
  defp only_tenants(query, _column, nil), do: query

  defp only_tenants(query, column, tenants),
    do: from(r in query, where: field(r, ^column) in ^tenants)

  @spec except_tenants(Ecto.Query.t(), atom(), [String.t()]) :: Ecto.Query.t()
  defp except_tenants(query, _column, []), do: query

  defp except_tenants(query, column, tenants),
    do: from(r in query, where: field(r, ^column) not in ^tenants)

  defp no_primary_key_message(schema) do
    "#{inspect(schema)} declares no primary key, so the migrator has nothing " <>
      "to page over. Keyset pagination needs a single column with a total " <>
      "order (ADR-0002 decision 6)."
  end

  defp composite_key_message(schema, columns) do
    "#{inspect(schema)} has the composite primary key #{inspect(columns)}, " <>
      "which the founding implementation does not support: tuple comparison " <>
      "is not expressed uniformly across adapters, and paging over one " <>
      "column of it would skip rows. Single-column integer and binary " <>
      "primary keys are supported (ADR-0002 proposed amendment 4). A real " <>
      "host arriving with a composite-key table is what reopens this."
  end

  defp unorderable_key_message(schema, column) do
    "#{inspect(schema)}'s primary key #{inspect(column)} is of type " <>
      "#{inspect(schema.__schema__(:type, column))}, which the migrator " <>
      "cannot page over: keyset pagination needs a total order the query " <>
      "builder expresses as one `>` comparison. Supported primary-key types " <>
      "are #{inspect(Map.keys(@orderable))} (ADR-0002 proposed amendment 4)."
  end
end
