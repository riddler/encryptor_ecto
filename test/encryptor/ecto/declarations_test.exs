defmodule Encryptor.Ecto.DeclarationsTest do
  use ExUnit.Case, async: true

  alias Encryptor.Ecto.Declarations
  alias Encryptor.Ecto.TestSchemas.Card
  alias Encryptor.Ecto.TestTypes

  doctest Encryptor.Ecto.Declarations

  # The fixtures live in the test file rather than in `test/support` on
  # purpose: `test/support` is compiled into the application, so a colliding
  # pair declared there would be found by every `apps: [:encryptor_ecto]` call
  # in this file, including the ones asserting that a clean set passes.

  defmodule Renamed do
    @moduledoc "A physically renamed column whose declared context is pinned to the old one."

    use Ecto.Schema

    schema "payment_cards" do
      field(:pan, TestTypes.Pan, table: "cards", column: "pan", source: :pan_enc)
    end
  end

  defmodule ReadModel do
    @moduledoc "A second schema over the same physical column - legitimate, not a collision."

    use Ecto.Schema

    schema "cards" do
      field(:pan, TestTypes.Pan)
    end
  end

  defmodule Signup do
    @moduledoc "A second table's encrypted field, deriving its own declared pair."

    use Ecto.Schema

    schema "signup_attempts" do
      field(:variant, TestTypes.Pan)
    end
  end

  defmodule Legacy do
    @moduledoc "A second column of the same table pinned to another column's declared pair."

    use Ecto.Schema

    schema "cards" do
      field(:notes, TestTypes.Pan, table: "cards", column: "pan")
    end
  end

  defmodule Attempt do
    @moduledoc "A different column pinned to the same declared pair - the accident."

    use Ecto.Schema

    schema "signup_attempts" do
      field(:variant, TestTypes.Pan, table: "cards", column: "pan")
    end
  end

  defmodule Plain do
    @moduledoc "A parameterized type of someone else's, carrying table and column params."

    @behaviour Ecto.ParameterizedType

    @doc false
    @impl Ecto.ParameterizedType
    def init(opts), do: %{table: "cards", column: "pan", opts: opts}

    @doc false
    @impl Ecto.ParameterizedType
    def type(_params), do: :string

    @doc false
    @impl Ecto.ParameterizedType
    def cast(value, _params), do: {:ok, value}

    @doc false
    @impl Ecto.ParameterizedType
    def dump(value, _dumper, _params), do: {:ok, value}

    @doc false
    @impl Ecto.ParameterizedType
    def load(value, _loader, _params), do: {:ok, value}

    @doc false
    @impl Ecto.ParameterizedType
    def equal?(left, right, _params), do: left == right

    @doc false
    @impl Ecto.ParameterizedType
    def embed_as(_format, _params), do: :self
  end

  defmodule Unrelated do
    @moduledoc "A schema whose parameterized field is not one of ours."

    use Ecto.Schema

    schema "signup_variants" do
      field(:label, Plain)
    end
  end

  describe "list/1" do
    # sabotage: declaration/2's `source_column` -> the field name, red.
    test "reports the declared pair and the physical one it was pinned away from" do
      assert [declaration] = Declarations.list(schemas: [Renamed])

      assert %{
               schema: Renamed,
               field: :pan,
               type: TestTypes.Pan,
               table: "cards",
               column: "pan",
               source: "payment_cards",
               source_column: :pan_enc
             } = declaration
    end

    # sabotage: declarations_in/1's Enum.reject(&is_nil/1) deleted, red.
    #
    # `holder_name` is an `Encryptor.Ecto.String` field and `metadata` an
    # `Encryptor.Ecto.Map` one: both freeze a declared context and both are
    # substitutable with a colliding declaration, so both are declarations
    # here. Only `merchant_id`, which this package does not encrypt, is passed
    # over.
    test "passes over the fields that are not encrypted" do
      assert Declarations.list(schemas: [Card]) |> Enum.map(& &1.field) ==
               [:holder_name, :metadata, :notes, :pan]
    end

    # sabotage: encrypted?/1 -> true, red. A foreign parameterized type whose
    # params happen to carry :table and :column is not this package's field,
    # and must not appear in a report about this package's fields.
    test "passes over a parameterized type that is not one of ours" do
      assert Declarations.list(schemas: [Unrelated]) == []
    end

    # sabotage: list/1's Enum.sort_by/2 dropped, red.
    test "sorts by the declared pair, so two runs report the same order" do
      pairs =
        [schemas: [Signup, Card]]
        |> Declarations.list()
        |> Enum.map(&{&1.table, &1.column, &1.schema})

      assert pairs == [
               {"cards", "holder_name", Card},
               {"cards", "metadata", Card},
               {"cards", "notes", Card},
               {"cards", "pan", Card},
               {"signup_attempts", "variant", Signup}
             ]
    end

    # sabotage: list/1's Enum.uniq/1 dropped, red. A host that names an
    # application and one of its schemas gets the schema twice otherwise, and
    # a doubled declaration is not a collision.
    test "reports a schema named twice once" do
      assert length(Declarations.list(schemas: [Card, Card])) == 4
    end

    # sabotage: modules_of/1's {:ok, modules} arm -> [], red.
    test "finds an application's schemas through :apps" do
      declarations = Declarations.list(apps: [:encryptor_ecto])

      assert Enum.any?(declarations, &match?(%{schema: Card, field: :pan}, &1))
      refute Enum.any?(declarations, &match?(%{schema: Renamed}, &1))
    end

    # sabotage: schema?/1's function_exported? half -> true, red.
    test "an application's non-schema modules are filtered rather than refused" do
      assert Declarations.list(apps: [:encryptor_ecto]) != []
    end
  end

  describe "check_unique!/1" do
    # sabotage: check_unique!/1's [] -> :ok arm returning the collisions, red.
    test "passes a set whose declared pairs are all distinct" do
      assert Declarations.check_unique!(schemas: [Card, Signup]) == :ok
    end

    # sabotage: collisions/1's `> 1` -> `> 0`, red - every declaration would
    # be its own collision.
    #
    # The renamed schema pins the pair its rows were written under, and the
    # schema it replaced is gone - which is why this is checked alone. Pinning
    # while the old schema is still declared is a collision, correctly: for as
    # long as both exist, both read the same rows.
    test "passes a renamed physical column pinned to its original pair" do
      assert Declarations.check_unique!(schemas: [Renamed]) == :ok
    end

    # sabotage: collisions/1's `> 1` -> `> 2`, red.
    test "refuses two different columns pinned to one declared pair" do
      error =
        assert_raise ArgumentError, fn ->
          Declarations.check_unique!(schemas: [Card, Attempt])
        end

      message = Exception.message(error)

      assert message =~ "the declared encryption context is not unique"
      assert message =~ ~s("cards" / "pan" is declared by)
      assert message =~ "DeclarationsTest.Attempt.variant (physically signup_attempts.variant"
      assert message =~ "TestSchemas.Card.pan (physically cards.pan"
      assert message =~ "mutually substitutable"
    end

    # sabotage: collisions/1's group_by keyed on the table alone, red - two
    # schemas over one physical column are the same column, not a collision,
    # and a check that failed them is one hosts turn off.
    test "allows two schemas over the same physical column" do
      assert Declarations.check_unique!(schemas: [Card, ReadModel]) == :ok
    end

    # sabotage: physical_columns/1 comparing the declared column rather than
    # the physical one, red. Two columns of the *same* table pinned to one
    # declared pair are the case that mutation cannot see, because their
    # declared pairs are equal by construction.
    test "refuses two columns of one table pinned to the same declared pair" do
      error =
        assert_raise ArgumentError, fn ->
          Declarations.check_unique!(schemas: [Card, Legacy])
        end

      assert Exception.message(error) =~ "DeclarationsTest.Legacy.notes (physically cards.notes"
      assert Exception.message(error) =~ "TestSchemas.Card.pan (physically cards.pan"
    end

    # sabotage: collisions/1's Enum.filter -> Enum.reject, red.
    test "names only the pairs that actually collide" do
      error =
        assert_raise ArgumentError, fn ->
          Declarations.check_unique!(schemas: [Card, Attempt])
        end

      refute Exception.message(error) =~ "notes"
    end

    # sabotage: modules_of/1's Application.load/1 call deleted, red on a cold
    # application - the module list of an unloaded application is :undefined.
    test "passes over an application whose schemas are all distinct" do
      assert Declarations.check_unique!(apps: [:encryptor_ecto]) == :ok
    end
  end

  describe "the scope it is given" do
    # sabotage: schema_modules/1's empty-scope raise deleted, red.
    test "refuses to guess when neither :apps nor :schemas is given" do
      assert_raise ArgumentError, ~r/needs somewhere to look/, fn ->
        Declarations.check_unique!([])
      end
    end

    # sabotage: modules_of/1's :undefined arm -> [], red.
    test "refuses an application it cannot load" do
      assert_raise ArgumentError, ~r/is not a loadable OTP application/, fn ->
        Declarations.list(apps: [:no_such_application_here])
      end
    end

    # sabotage: assert_schema!/1's else arm -> :ok, red.
    test "refuses a named module that is not an Ecto schema" do
      assert_raise ArgumentError, ~r/named in :schemas but is not an Ecto schema/, fn ->
        Declarations.list(schemas: [TestTypes.Pan])
      end
    end
  end
end
