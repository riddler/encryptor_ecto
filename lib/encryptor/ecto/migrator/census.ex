defmodule Encryptor.Ecto.Migrator.Census do
  @moduledoc """
  The SQL half of verification: what a plan's tables look like, read with no
  application and no key.

  ADR-0002 decision 10. `Encryptor.Ecto.Migrator.verify/2` above these is the
  authoritative answer - it opens the bytes and is therefore the acceptance
  test. These are the cheap ones, and they exist for two people the verifier
  does not serve:

    * the **operator watching a six-hour pass**, who should be able to see
      where it has got to without running the application against production
      credentials to find out;
    * the **DBA reviewing the change**, who should be able to confirm the
      outcome without being handed a key.

  So nothing here connects to a repository, decrypts anything, or needs the
  vault to be running. `queries/2` renders SQL text against a plan's own table
  and column names, and what an operator does with it is paste it into `psql`.

  ## Target-or-not, and the prefix that has to be wider than one byte

  The census asks whether a row is in **this package's** format, and answers
  nothing else. Distinguishing "not one of ours" from "one of theirs" would
  need a decoder for a format this package has no correctness obligation to
  (ADR-0004 decision 11), so it is not attempted and the queries are written
  as target-or-not.

  There is a trap in the cheap version of that question, and it is the reason
  `header_bytes/0` is four rather than one: `cloak_ecto`'s envelope opens with a
  reserved `0x01` byte, and this package's messages open with a version byte
  of their own. A census keyed on the **first byte alone** can therefore read
  as identical across both formats - a report that says "one format, all
  migrated" over a table that is half legacy. Grouping on a wider prefix is
  what separates them.

  The queries group rather than test, which is the same defensiveness one
  level up: the census does not assert "this prefix is ours", it prints every
  prefix present with a count beside it, and the operator reads which one is
  growing. A host on a legacy format whose fifth byte happens to collide gets
  a census that looks wrong rather than one that lies.

  ## The three queries

  | Kind | Answers |
  |---|---|
  | `:format` | Which formats are in this column, and how many rows of each |
  | `:progress` | For one tenant, how far the rotation has got |
  | `:integrity` | Nothing became `NULL` and nothing became empty. Run before, run after, compare |

  `:progress` is emitted only for a rewrite that resolves its tenant from a
  column (`tenant_from`). A rewrite whose tenant is `:none` or a resolver
  module has no tenant column to filter on, and a per-tenant progress query
  over it would either be a whole-table count wearing a tenant's name or a
  guess about where the tenant lives.

  ## Placeholders, and why the header is one

  Two of the queries carry `:placeholder` names for the operator to
  substitute, because neither value is knowable from the plan: `:tenant` is
  whichever tenant is being watched, and `:current_header` is the byte prefix
  the target format is currently writing.

  The operator gets `:current_header` from the `:format` query on the same
  column rather than from any key: once the new type modules are live, the
  prefix whose count is **growing** is the target one. That keeps the whole
  set keyless, which is the property the whole module exists for.

  ## Dialect

  PostgreSQL, which is what ADR-0002 decision 10 wrote and what this package
  tests against. `substring(x from 1 for n)`, `count(*) FILTER (WHERE ...)`
  and `octet_length/1` are the three constructs that are not portable to every
  adapter; a host on another one translates three lines, and the shape of the
  question is unchanged.
  """

  alias Encryptor.Ecto.Migrator.Plan

  # Wide enough to separate two formats whose first byte collides, and short
  # enough to stay inside the shortest header either format writes. ADR-0002
  # decision 10's own SQL uses four; ADR-0004 decision 11 records why one is
  # wrong.
  @header_bytes 4

  @typedoc "Which question a census query answers. See the moduledoc's table."
  @type kind :: :format | :progress | :integrity

  @typedoc """
  One rendered query, and enough about it to print a heading over it.

  `:column` is the column the query reads, which for the backfill leg of an
  adoption migration (`into:`) is the **target** column rather than the field
  the plan names: the census is about what has arrived in the new format.
  """
  @type query :: %{
          kind: kind(),
          schema: module(),
          field: atom(),
          table: String.t(),
          column: String.t(),
          placeholders: [atom()],
          sql: String.t()
        }

  @doc """
  How many leading bytes the format census groups on.

      iex> Encryptor.Ecto.Migrator.Census.header_bytes()
      4
  """
  @spec header_bytes() :: pos_integer()
  def header_bytes, do: @header_bytes

  @doc """
  Every census query for a plan, in the order the plan declares its fields.

  Options:

  | Option | Default | |
  |---|---|---|
  | `:prefix` | `nil` | The schema prefix the tables live in |

  `:prefix` is here for the same reason `verify/2` takes one: a census of a
  different prefix than the pass wrote to is worse than no census. It is the
  schema prefix (a PostgreSQL schema), and is unrelated to `header_bytes/0`'s
  byte prefix, which is a fact about the ciphertext.
  """
  @spec queries(module(), keyword()) :: [query()]
  def queries(plan_module, opts \\ []) do
    plan = Plan.fetch!(plan_module, "Encryptor.Ecto.Migrator.Census.queries/2")
    prefix = Keyword.get(opts, :prefix)

    Enum.flat_map(plan.rewrites, &rewrite_queries(&1, prefix))
  end

  @doc """
  The queries as one runnable script, each under a comment saying what it is.

  This is the form an operator is handed: `queries/2` is for a caller that
  wants to render them its own way.
  """
  @spec script([query()]) :: String.t()
  def script(queries) do
    Enum.map_join(queries, "\n", fn query ->
      "-- #{heading(query)}\n#{query.sql}\n"
    end)
  end

  @spec heading(query()) :: String.t()
  defp heading(%{kind: :format} = query),
    do: "#{named(query)}: format census, grouped on #{@header_bytes} bytes"

  defp heading(%{kind: :progress} = query),
    do: "#{named(query)}: rotation progress for one tenant"

  defp heading(%{kind: :integrity} = query),
    do: "#{named(query)}: nothing became NULL or empty"

  @spec named(query()) :: String.t()
  defp named(query), do: "#{query.table}.#{quoted(query.column)}"

  @spec rewrite_queries(Plan.rewrite(), String.t() | nil) :: [query()]
  defp rewrite_queries(rewrite, prefix) do
    table = table(rewrite.schema, prefix)

    Enum.flat_map(rewrite.fields, fn {field, spec} ->
      source = Atom.to_string(field)
      # `into:` is present and `nil` on an ordinary rewrite, so the default
      # has to be an `||` rather than `Keyword.get/3`'s third argument - the
      # same shape `Encryptor.Ecto.Migrator.pass!/5` reads it with.
      target = Atom.to_string(Keyword.get(spec, :into) || field)
      context = %{schema: rewrite.schema, field: field, table: table, column: target}

      [format(context), integrity(context, source)] ++ progress(context, rewrite.tenant)
    end)
  end

  # Every prefix present in the column with a count beside it, biggest first,
  # rather than a test against one prefix - see the moduledoc.
  @spec format(map()) :: query()
  defp format(context) do
    column = quoted(context.column)

    sql = """
    SELECT substring(#{column} from 1 for #{@header_bytes}) AS header,
           count(*) AS rows
    FROM #{context.table}
    WHERE #{column} IS NOT NULL
    GROUP BY 1
    ORDER BY 2 DESC;\
    """

    Map.merge(context, %{kind: :format, placeholders: [], sql: sql})
  end

  @spec progress(map(), Plan.tenant()) :: [query()]
  defp progress(context, {:column, tenant_column}) do
    column = quoted(context.column)

    sql = """
    SELECT count(*) FILTER (
             WHERE substring(#{column} from 1 for #{@header_bytes}) = :current_header
           ) AS done,
           count(*) FILTER (WHERE #{column} IS NOT NULL) AS total
    FROM #{context.table}
    WHERE #{quoted(tenant_column)} = :tenant;\
    """

    [Map.merge(context, %{kind: :progress, placeholders: [:current_header, :tenant], sql: sql})]
  end

  defp progress(_context, _tenant), do: []

  # The ordinary rewrite reads and writes one column, so "did anything become
  # NULL?" is a question about that column before and after. The backfill leg
  # of an adoption migration has two, and the comparison an operator needs is
  # between them - a target that is NULL where the source is not is a row the
  # backfill has not reached, and a target that is empty where the source is
  # not is the failure this query is really watching for.
  @spec integrity(map(), String.t()) :: query()
  defp integrity(%{column: column} = context, column) do
    quoted = quoted(column)

    sql = """
    SELECT count(*) AS rows,
           count(#{quoted}) AS non_null,
           count(*) FILTER (WHERE octet_length(#{quoted}) = 0) AS empty
    FROM #{context.table};\
    """

    Map.merge(context, %{kind: :integrity, placeholders: [], sql: sql})
  end

  defp integrity(context, source) do
    target = quoted(context.column)

    sql = """
    SELECT count(*) AS rows,
           count(#{quoted(source)}) AS source_non_null,
           count(#{target}) AS target_non_null,
           count(*) FILTER (WHERE octet_length(#{target}) = 0) AS target_empty
    FROM #{context.table};\
    """

    Map.merge(context, %{kind: :integrity, placeholders: [], sql: sql})
  end

  @spec table(module(), String.t() | nil) :: String.t()
  defp table(schema, nil), do: quoted(schema.__schema__(:source))
  defp table(schema, prefix), do: "#{quoted(prefix)}.#{quoted(schema.__schema__(:source))}"

  # Every identifier is double-quoted, so a table or column whose name is a
  # reserved word renders a query that runs rather than one the operator has
  # to fix by hand. The names come from the schema modules the plan named, not
  # from anything a request reached.
  @spec quoted(atom() | String.t()) :: String.t()
  defp quoted(name) when is_atom(name), do: quoted(Atom.to_string(name))
  defp quoted(name), do: ~s("#{name}")
end
