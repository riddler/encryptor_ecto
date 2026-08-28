defmodule Encryptor.Ecto.Declarations do
  @moduledoc """
  The declared encryption contexts a host's schemas carry, and the check that
  no two of them are the same (ADR-0001 decision 4, acceptance amendment 5).

  Every encrypted field freezes a declared `"table"` and `"column"` at
  declaration time, and every message it writes is authenticated under that
  pair. Two fields that share one declared pair are therefore *mutually
  substitutable*: bytes written by one decrypt cleanly when loaded by the
  other, under the same tenant key. That is exactly the property the
  encryption context exists to deny, and nothing about the declarations
  themselves makes the overlap visible - the two modules need never mention
  each other.

  ## Why this is a start-time check rather than a compile-time one

  The obvious shape is a module attribute accumulated at compile time. It
  cannot work: an accumulator sees only the declarations that reach *one*
  compilation unit, and the two colliding declarations are, by construction,
  in modules that never reference each other. The check has to run at a point
  where the whole set is knowable, and that point is start time, over the
  modules an application's `.app` file lists.

  So there is no registry process and no persisted state here - nothing to
  start, nothing to keep in sync. `check_unique!/1` is a pure function over
  loaded modules, and the host calls it where it wants the failure:

      defmodule Payments.Application do
        use Application

        @impl Application
        def start(_type, _args) do
          :ok = Encryptor.Ecto.Declarations.check_unique!(apps: [:payments])

          Supervisor.start_link(children(), strategy: :one_for_one, name: Payments.Supervisor)
        end
      end

  Calling it from `start/2` makes a collision a boot failure on the first
  deploy that introduces it, which is the only moment it is free to fix. A
  host that would rather not fail its boot can call the same function from a
  test instead; what it must not do is leave the pair unchecked, because the
  overlap is silent in every other way.

  ## What counts as a collision

  Two declarations collide when they share a declared `{table, column}` pair
  **and do not describe the same physical column**. The second half matters:
  two `Ecto` schemas over one table - a read model, a partial schema, an
  archival twin - legitimately declare the same field, and they are not
  substitutable for each other because they *are* each other. A check that
  failed those would be a check hosts turn off. Physical identity is the
  schema's source table and the field's own `:source` column, so the genuine
  accident (two different columns pinned to one declared pair) still collides,
  and the legitimate duplicate does not.

  Note what is *not* part of the comparison: the vault. Two fields sharing a
  declared pair on different vaults cannot actually decrypt each other's
  bytes, but a vault is a deployment-time binding that a later refactor can
  make the same, and the declared pair is the durable property. The check is
  the stricter one on purpose.

  ## Renaming, and what a rename costs

  Since the declared values are frozen at declaration, renaming the physical
  table or column is free: pin the old values with `:table` and `:column` and
  stored rows stay readable.

      defmodule Payments.Cards.Card do
        use Ecto.Schema

        # The physical table is `payment_cards` now; the declared context is
        # still what the rows were written under.
        schema "payment_cards" do
          field :pan, Payments.Encrypted.Binary, table: "cards", column: "pan"
        end
      end

  Changing a *declared* value is the opposite: it invalidates every row in the
  column and is an R3 migration (ADR-0002). The rename that used to be the
  expensive one is the cheap one, and the cheap-looking one is the expensive
  one - which is the whole point of freezing them.
  """

  @typedoc """
  One encrypted field declaration.

  `:table` and `:column` are the frozen declared values - what goes into the
  encryption context. `:source` and `:source_column` are the physical table
  and column, which are only the same strings when the declaration was derived
  rather than pinned.
  """
  @type declaration :: %{
          schema: module(),
          field: atom(),
          type: module(),
          table: String.t(),
          column: String.t(),
          source: String.t() | nil,
          source_column: atom()
        }

  @typedoc """
  Where to look for declarations.

  `:apps` names OTP applications and reads every module in each one's `.app`
  file - the ordinary host call. `:schemas` names schema modules directly,
  which is what a test wants. At least one of the two is required: there is no
  "check everything" default, because a library's opinion about which
  applications a host meant is always wrong.
  """
  @type scope :: [apps: [atom()], schemas: [module()]]

  @doc """
  Raises unless every declared `{table, column}` pair is unique.

  Returns `:ok` when it is. See the moduledoc for what counts as a collision
  and for where a host calls this.

      iex> Encryptor.Ecto.Declarations.check_unique!(schemas: [Encryptor.Ecto.TestSchemas.Card])
      :ok
  """
  @spec check_unique!(scope()) :: :ok
  def check_unique!(scope) do
    case scope |> list() |> collisions() do
      [] -> :ok
      collisions -> raise ArgumentError, collision_message(collisions)
    end
  end

  @doc """
  Lists every encrypted field declaration in scope, sorted by declared pair.

  Useful on its own: it is the answer to "what does this deploy consider
  encrypted, and under what context", which is otherwise spread across every
  schema in the application.

      iex> Encryptor.Ecto.Declarations.list(schemas: [Encryptor.Ecto.TestSchemas.Card])
      ...> |> Enum.map(&{&1.table, &1.column})
      [{"cards", "notes"}, {"cards", "pan"}]
  """
  @spec list(scope()) :: [declaration()]
  def list(scope) do
    scope
    |> schema_modules()
    |> Enum.flat_map(&declarations_in/1)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.table, &1.column, inspect(&1.schema), &1.field})
  end

  # -- what to look at ------------------------------------------------------

  @spec schema_modules(scope()) :: [module()]
  defp schema_modules(scope) do
    apps = Keyword.get(scope, :apps, [])
    schemas = Keyword.get(scope, :schemas, [])

    if apps == [] and schemas == [] do
      raise ArgumentError, no_scope_message()
    end

    Enum.each(schemas, &assert_schema!/1)

    apps
    |> Enum.flat_map(&modules_of/1)
    |> Enum.filter(&schema?/1)
    |> Enum.concat(schemas)
  end

  # `Application.load/1` rather than `ensure_all_started/1`: reading the
  # module list needs the application loaded, not running, and a check that
  # started applications as a side effect would be a surprising thing to call
  # from inside a supervision tree's start.
  @spec modules_of(atom()) :: [module()]
  defp modules_of(app) when is_atom(app) do
    _ = Application.load(app)

    case :application.get_key(app, :modules) do
      {:ok, modules} -> modules
      :undefined -> raise ArgumentError, unknown_app_message(app)
    end
  end

  # `Code.ensure_loaded?/1` before `function_exported?/2`, for the reason
  # `Encryptor.Ecto.Binary` gives at its own use of the pair: the bare export
  # check answers false for a module that is merely not loaded yet, which
  # under lazy loading is the ordinary case for a schema this process has not
  # touched. A check whose answer depends on load order is worse than no
  # check, because it passes in the suite that would have caught the collision.
  @spec schema?(module()) :: boolean()
  defp schema?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1)
  end

  @spec assert_schema!(module()) :: :ok
  defp assert_schema!(module) do
    if schema?(module) do
      :ok
    else
      raise ArgumentError,
            "#{inspect(module)} was named in :schemas but is not an Ecto schema. " <>
              "Modules found through :apps are filtered; ones named directly are not, " <>
              "because a misspelled schema silently checking nothing is the failure " <>
              "this function exists to prevent."
    end
  end

  # -- reading a declaration ------------------------------------------------

  @spec declarations_in(module()) :: [declaration()]
  defp declarations_in(schema) do
    :fields
    |> schema.__schema__()
    |> Enum.map(&declaration(schema, &1))
    |> Enum.reject(&is_nil/1)
  end

  @spec declaration(module(), atom()) :: declaration() | nil
  defp declaration(schema, field) do
    with {:parameterized, {type, %{table: table, column: column}}} <-
           schema.__schema__(:type, field),
         true <- encrypted?(type) do
      %{
        schema: schema,
        field: field,
        type: type,
        table: table,
        column: column,
        source: schema.__schema__(:source),
        source_column: schema.__schema__(:field_source, field) || field
      }
    else
      _not_ours -> nil
    end
  end

  # The marker `use Encryptor.Ecto.Binary` defines on the host type module.
  # Recognising our own types by a marker rather than by the shape of their
  # params keeps an unrelated parameterized type that happens to carry
  # `:table` and `:column` keys out of the check, and out of its failure
  # message.
  @spec encrypted?(module()) :: boolean()
  defp encrypted?(type) when is_atom(type) do
    Code.ensure_loaded?(type) and function_exported?(type, :__encryptor_ecto__, 1)
  end

  # -- the check ------------------------------------------------------------

  @spec collisions([declaration()]) :: [{{String.t(), String.t()}, [declaration()]}]
  defp collisions(declarations) do
    declarations
    |> Enum.group_by(&{&1.table, &1.column})
    |> Enum.filter(fn {_pair, declared} -> length(physical_columns(declared)) > 1 end)
    |> Enum.sort_by(fn {pair, _declared} -> pair end)
  end

  @spec physical_columns([declaration()]) :: [{String.t() | nil, atom()}]
  defp physical_columns(declared) do
    declared |> Enum.map(&{&1.source, &1.source_column}) |> Enum.uniq()
  end

  # -- messages -------------------------------------------------------------

  defp collision_message(collisions) do
    """
    the declared encryption context is not unique across these field \
    declarations:

    #{Enum.map_join(collisions, "\n", &render_collision/1)}

    Fields sharing a declared table and column are mutually substitutable: \
    bytes written by one decrypt cleanly when loaded by the other, under the \
    same tenant key, which is the property the encryption context exists to \
    deny (ADR-0001 decision 4).

    Give each field a declared pair of its own with the :table and :column \
    options. Note that this is a choice about stored rows rather than about \
    source: changing the declared pair a column has already been written \
    under invalidates every row in it and is a re-encryption migration.
    """
  end

  defp render_collision({{table, column}, declared}) do
    "  #{inspect(table)} / #{inspect(column)} is declared by:\n" <>
      Enum.map_join(declared, "\n", &render_declaration/1)
  end

  defp render_declaration(declaration) do
    "    - #{inspect(declaration.schema)}.#{declaration.field} " <>
      "(physically #{declaration.source}.#{declaration.source_column}, " <>
      "type #{inspect(declaration.type)})"
  end

  defp no_scope_message do
    """
    Encryptor.Ecto.Declarations needs somewhere to look: pass :apps, :schemas, \
    or both.

        Encryptor.Ecto.Declarations.check_unique!(apps: [:payments])

    There is no default. A library guessing which applications a host meant \
    to check would be wrong in the direction that matters - quietly checking \
    nothing.
    """
  end

  defp unknown_app_message(app) do
    """
    #{inspect(app)} is not a loadable OTP application, so its modules cannot \
    be listed.

    Name applications, not modules: :apps takes OTP application names and \
    :schemas takes schema modules.
    """
  end
end
