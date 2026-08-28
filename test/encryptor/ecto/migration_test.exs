defmodule Encryptor.Ecto.MigrationTest do
  use ExUnit.Case, async: true

  alias Encryptor.Ecto.Migrator.Plan
  alias Encryptor.Ecto.Migrator.Source
  alias Encryptor.Ecto.TestPlans
  alias Encryptor.Ecto.TestSchemas.Card

  doctest Encryptor.Ecto.Migration

  defmodule ReadOnlyTarget do
    @moduledoc "Loads at arity 3 and cannot dump - a half-written target."

    def init(opts), do: Map.new(opts)
    def type(_params), do: :binary
    def cast(value, _params), do: {:ok, value}
    def load(value, _loader, _params), do: {:ok, value}
  end

  defmodule PlainTarget do
    @moduledoc "A plain `Ecto.Type` target: loads and dumps at arity 1."

    def type, do: :binary
    def cast(value), do: {:ok, value}
    def load(value), do: {:ok, value}
    def dump(value), do: {:ok, value}
  end

  # A plan module compiled from source, so a refusal is observable as the
  # `CompileError` a host would see. Each gets a unique name: a redefinition
  # warning would be noise, and a leftover module from an earlier test would
  # make the next one's failure depend on the order they ran in.
  defp compile(source) do
    Code.compile_string(source, "plan.ex")
  end

  defp compile_plan(body, use_opts \\ "repo: Encryptor.Ecto.TestRepo") do
    use_line =
      case use_opts do
        "" -> "use Encryptor.Ecto.Migration"
        opts -> "use Encryptor.Ecto.Migration, #{opts}"
      end

    compile("""
    defmodule #{unique_name()} do
      #{use_line}
    #{body}
    end
    """)
  end

  defp compile_rewrite(body, schema \\ "Encryptor.Ecto.TestSchemas.Card") do
    compile_plan("""
      rewrite #{schema} do
    #{body}
      end
    """)
  end

  defp unique_name do
    "Encryptor.Ecto.MigrationTest.Generated#{System.unique_integer([:positive])}"
  end

  defp refusal(fun) do
    fun |> assert_compile_error() |> Exception.message()
  end

  defp assert_compile_error(fun) do
    assert_raise CompileError, fun
  end

  describe "the compiled plan" do
    # Sabotage: `__before_compile__`'s `Enum.reverse(rewrites)` dropped - the
    # accumulated attribute is in reverse declaration order, so a plan read
    # its schemas backwards.
    test "carries the repo and the rewrites in declaration order" do
      assert %Plan{repo: Encryptor.Ecto.TestRepo, rewrites: [card, signup]} =
               TestPlans.Cloak.__plan__()

      assert card.schema == Card
      assert signup.schema == Encryptor.Ecto.TestSchemas.Signup
    end

    # Sabotage: `__close__`'s `Enum.reverse(rewrite.fields)` dropped - the
    # fields came back reversed, and the report would name them in an order
    # the plan does not.
    test "carries the fields of a rewrite in declaration order" do
      %Plan{rewrites: [rewrite, _signup]} = TestPlans.Cloak.__plan__()

      assert [{:pan, _pan}, {:notes, _notes}] = rewrite.fields
    end

    # Sabotage: `tenant_from/1` quoting `unquote(column)` instead of
    # `{:column, unquote(column)}` - red before the suite ran, because the
    # fixture plan is compiled by the compiler and a bare atom reaches the
    # resolver-module arm, which refuses it.
    test "records tenant_from as the column to read off each row" do
      %Plan{rewrites: [rewrite, _signup]} = TestPlans.Cloak.__plan__()

      assert rewrite.tenant == {:column, :merchant_id}
    end

    # Sabotage: `validate_tenant!(:none, ...)` returning something other than
    # `:none` - a global field would be resolved as if it named a resolver.
    test "records tenant :none as declared" do
      %Plan{rewrites: [rewrite]} = TestPlans.ContextChange.__plan__()

      assert rewrite.tenant == :none
    end

    # Sabotage: `validate_tenant!/3`'s module arm returning `:none` - a host
    # resolver was silently replaced by "this field is global".
    test "records a resolver module as declared" do
      %Plan{rewrites: [rewrite]} = TestPlans.Adoption.__plan__()

      assert rewrite.tenant == Encryptor.Ecto.TestResolvers.Fixed
    end

    # Sabotage: the field spec's `source:` entry dropped - the plan compiled
    # and the resolution ADR-0004 decision 2 fixes at compile time was gone.
    test "carries the source resolve!/2 decided for the from: module" do
      %Plan{rewrites: [rewrite, _signup]} = TestPlans.Cloak.__plan__()
      {:pan, spec} = List.keyfind(rewrite.fields, :pan, 0)

      assert spec[:from] == Encryptor.Ecto.TestSources.LegacyType
      assert spec[:to] == Encryptor.Ecto.TestTypes.Pan
      assert spec[:into] == nil

      assert spec[:source] ==
               {Source.EctoType,
                %{source_module: Encryptor.Ecto.TestSources.LegacyType, source_arity: 1}}
    end

    # Sabotage: `validate_into!/3`'s atom arm returning `nil` - the backfill
    # leg wrote back over the plaintext column it read.
    test "carries into: as the target column of a backfill" do
      %Plan{rewrites: [rewrite]} = TestPlans.Adoption.__plan__()
      {:email, spec} = List.keyfind(rewrite.fields, :email, 0)

      assert spec[:into] == :email_encrypted
      assert spec[:source] == {Encryptor.Ecto.Migrator.Source.Plaintext, %{}}
    end

    # Sabotage: added a `from == to` refusal to `__field__` - red before the
    # suite ran, since the fixture plan stopped compiling: the context change
    # ADR-0002 decision 3 names had become inexpressible.
    test "accepts the same module on both sides, which is a context change" do
      %Plan{rewrites: [rewrite]} = TestPlans.ContextChange.__plan__()
      {:pan, spec} = List.keyfind(rewrite.fields, :pan, 0)

      assert spec[:from] == spec[:to]
    end

    # Sabotage: `@behaviour` dropped from `__using__` - `__plan__/0` was still
    # defined, but nothing checked the plan module against the contract.
    test "is reachable through the behaviour" do
      assert Encryptor.Ecto.Migration in TestPlans.Cloak.__info__(:attributes)[:behaviour]
    end
  end

  describe "the use options" do
    # Sabotage: `__repo__!`'s `:error` arm returning `nil` - a plan with no
    # repo compiled, and failed when the migrator went to query.
    test "refuse a plan that names no repo" do
      message = refusal(fn -> compile_plan("", "") end)

      assert message =~ "requires `repo:`"
    end

    # Sabotage: `assert_repo!/2` returning the module unconditionally - a
    # schema named where the repo goes compiled.
    test "refuse a repo module that is not one" do
      message = refusal(fn -> compile_plan("", "repo: Encryptor.Ecto.TestSchemas.Card") end)

      assert message =~ "is not an Ecto repo"
      assert message =~ "__adapter__/0"
    end

    # Sabotage: `refuse_unknown!/4`'s `given -- known` replaced by `[]` - a
    # misspelled option was accepted and did nothing.
    test "refuse an unknown option" do
      message =
        refusal(fn -> compile_plan("", "repo: Encryptor.Ecto.TestRepo, prefix: \"x\"") end)

      assert message =~ "unknown option [:prefix]"
      assert message =~ "[:repo]"
    end

    # Sabotage: `assert_keyword!/3` returning its input - `use` with a
    # non-keyword raised a FunctionClauseError from deep inside Keyword.
    test "refuse options that are not a keyword list" do
      message = refusal(fn -> compile_plan("", ":repo") end)

      assert message =~ "expects a keyword list"
    end
  end

  describe "the rewrite block" do
    # Sabotage: `__open__`'s `__schema__/1` check inverted - a plan rewrote a
    # module with no table and failed on the first query.
    test "refuses a module that is not an Ecto schema" do
      message = refusal(fn -> compile_rewrite("    tenant :none", "Encryptor.Ecto.Binary") end)

      assert message =~ "is not an Ecto schema"
      assert message =~ "__schema__/1"
    end

    # Sabotage: `__open__`'s duplicate check dropped - two rewrites of one
    # schema compiled, and their checkpoint cursors collided.
    test "refuses two rewrites of one schema" do
      message =
        refusal(fn ->
          compile_plan("""
            rewrite Encryptor.Ecto.TestSchemas.Card do
              tenant :none
              field :pan, from: Encryptor.Ecto.TestTypes.Pan, to: Encryptor.Ecto.TestTypes.Pan
            end

            rewrite Encryptor.Ecto.TestSchemas.Card do
              tenant :none
              field :notes, from: Encryptor.Ecto.TestTypes.Notes, to: Encryptor.Ecto.TestTypes.Notes
            end
          """)
        end)

      assert message =~ "rewritten twice"
    end

    # Sabotage: `__open__`'s nested-block refusal dropped - the inner block
    # overwrote the outer one's fields and the outer schema went unrewritten.
    test "refuses a nested rewrite" do
      message =
        refusal(fn ->
          compile_rewrite("""
              tenant :none

              rewrite Encryptor.Ecto.TestSchemas.Signup do
                tenant :none
              end
          """)
        end)

      assert message =~ "cannot contain another one"
    end

    # Sabotage: `__close__`'s empty-fields refusal dropped - a rewrite that
    # names no field compiled and silently rewrote nothing.
    test "refuses a rewrite that declares no fields" do
      message = refusal(fn -> compile_rewrite("    tenant :none") end)

      assert message =~ "declares no fields"
    end

    # Sabotage: `__before_compile__`'s empty-plan refusal dropped - an empty
    # plan compiled, ran, and reported success having done nothing.
    test "refuses a plan that declares no rewrites" do
      message = refusal(fn -> compile_plan("") end)

      assert message =~ "declares no rewrites"
    end

    # Sabotage: `open!/3` returning an empty rewrite instead of raising - a
    # stray `field` outside any block was attributed to no schema.
    test "refuses a declaration outside a rewrite block" do
      message =
        refusal(fn ->
          compile_plan("  tenant :none")
        end)

      assert message =~ "only be called inside a `rewrite` block"
    end
  end

  describe "the tenant strategy" do
    # Sabotage: `__close__`'s `tenant == nil` refusal dropped - a rewrite with
    # no tenant compiled, and every row resolved under no key at all.
    test "refuses a rewrite that declares none" do
      message =
        refusal(fn ->
          compile_rewrite(
            "    field :pan, from: Encryptor.Ecto.TestTypes.Pan, to: Encryptor.Ecto.TestTypes.Pan"
          )
        end)

      assert message =~ "declares no tenant"
    end

    # Sabotage: `__tenant__`'s duplicate refusal dropped - the second
    # declaration silently won over the first.
    test "refuses two declarations in one rewrite" do
      message =
        refusal(fn ->
          compile_rewrite("""
              tenant :none
              tenant_from :merchant_id
          """)
        end)

      assert message =~ "declares a tenant twice"
    end

    # Sabotage: `validate_tenant!/3`'s column membership check dropped - a
    # typo'd tenant column failed on row one, against production data.
    test "refuses a tenant_from column the schema does not have" do
      message = refusal(fn -> compile_rewrite("    tenant_from :account_id") end)

      assert message =~ "tenant_from names :account_id"
      assert message =~ "merchant_id"
    end

    # Sabotage: `validate_tenant!(:scope, ...)`'s raise replaced by `:scope` -
    # a plan compiled that would read an empty process scope for every row.
    test "refuses :scope, which a release command does not have" do
      message = refusal(fn -> compile_rewrite("    tenant :scope") end)

      assert message =~ "ambient state"
    end

    # Sabotage: `validate_tenant!/3`'s module arm returning the module without
    # the export check - a resolver that cannot resolve compiled.
    test "refuses a module that implements no resolve/2" do
      message =
        refusal(fn -> compile_rewrite("    tenant Encryptor.Ecto.TestSources.NotASource") end)

      assert message =~ "resolve/2"
      assert message =~ "TenantContext"
    end
  end

  describe "a field" do
    # Sabotage: `__field__`'s schema-membership check dropped - a misspelled
    # field compiled and the pass failed on its first query.
    test "must name a column of the schema" do
      message =
        refusal(fn ->
          compile_rewrite("""
              tenant :none
              field :pann, from: Encryptor.Ecto.TestTypes.Pan, to: Encryptor.Ecto.TestTypes.Pan
          """)
        end)

      assert message =~ "field names :pann"
      assert message =~ ":pan"
    end

    # Sabotage: `__field__`'s `List.keymember?` refusal dropped - one field
    # declared twice was rewritten twice in one pass.
    test "may not be declared twice in one rewrite" do
      message =
        refusal(fn ->
          compile_rewrite("""
              tenant :none
              field :pan, from: Encryptor.Ecto.TestTypes.Pan, to: Encryptor.Ecto.TestTypes.Pan
              field :pan, from: Encryptor.Ecto.TestTypes.Pan, to: Encryptor.Ecto.TestTypes.Pan
          """)
        end)

      assert message =~ "declared twice"
    end

    # Sabotage: `required_module!/5`'s `:error` arm returning `nil` - a field
    # with no `from:` compiled, and resolve!/2 was handed nil.
    test "must name a from: module" do
      message =
        refusal(fn ->
          compile_rewrite("""
              tenant :none
              field :pan, to: Encryptor.Ecto.TestTypes.Pan
          """)
        end)

      assert message =~ "declares no `from:`"
    end

    # Sabotage: the same arm - the `to:` half, which is the side that has to
    # write the rewritten bytes.
    test "must name a to: module" do
      message =
        refusal(fn ->
          compile_rewrite("""
              tenant :none
              field :pan, from: Encryptor.Ecto.TestTypes.Pan
          """)
        end)

      assert message =~ "declares no `to:`"
    end

    # Sabotage: `refuse_unknown!/4` skipped for fields - `source_authenticated:`
    # was accepted and ignored, which is the one way that option could be
    # worse than absent.
    test "refuses an unknown option, naming the ones it knows" do
      message =
        refusal(fn ->
          compile_rewrite("""
              tenant :none
              field :pan,
                from: Encryptor.Ecto.TestTypes.Pan,
                to: Encryptor.Ecto.TestTypes.Pan,
                source_authenticated: false
          """)
        end)

      assert message =~ "unknown option [:source_authenticated]"
      assert message =~ "[:from, :to, :into]"
    end

    # Sabotage: `validate_into!/3`'s membership check dropped - the backfill
    # wrote to a column the table does not have.
    test "refuses an into: column the schema does not have" do
      message =
        refusal(fn ->
          compile_rewrite("""
              tenant :none
              field :pan,
                from: Encryptor.Ecto.TestTypes.Pan,
                to: Encryptor.Ecto.TestTypes.Pan,
                into: :pan_encrypted
          """)
        end)

      assert message =~ "into: names :pan_encrypted"
    end

    # Sabotage: `required_module!/5`'s non-atom arm returning the value - a
    # string where a module goes reached `Code.ensure_compiled/1`.
    test "refuses a from: that is not a module" do
      message =
        refusal(fn ->
          compile_rewrite("""
              tenant :none
              field :pan, from: "MyApp.Legacy", to: Encryptor.Ecto.TestTypes.Pan
          """)
        end)

      assert message =~ "from: expects a module"
    end
  end

  describe "the type checks on both sides" do
    # Sabotage: the `Source.resolve!/2` call dropped from `__field__` - a
    # `from:` module that can read nothing compiled, which is exactly the
    # promise ADR-0002 decision 2 makes.
    test "refuse a from: module that can read nothing" do
      message =
        refusal(fn ->
          compile_rewrite("""
              tenant :none
              field :pan,
                from: Encryptor.Ecto.TestSources.NotASource,
                to: Encryptor.Ecto.TestTypes.Pan
          """)
        end)

      assert message =~ "Card.pan"
      assert message =~ "load/1"
    end

    # Sabotage: `assert_target!/4`'s `and exports?(module, :dump, 3)` half
    # dropped - a target that can read but not write compiled, and the pass
    # failed after decrypting a production row.
    test "refuse a to: module that loads but cannot dump" do
      message =
        refusal(fn ->
          compile_rewrite("""
              tenant :none
              field :pan,
                from: Encryptor.Ecto.TestTypes.Pan,
                to: Encryptor.Ecto.MigrationTest.ReadOnlyTarget
          """)
        end)

      assert message =~ "Card.pan"
      assert message =~ "cannot write the rewritten bytes"
    end

    # Sabotage: `assert_target!/4`'s arity-1 arm dropped - a plain `Ecto.Type`
    # target was refused, though it is what a host migrating between two
    # hand-rolled types names.
    test "accept a plain Ecto.Type on both sides" do
      assert [_ | _] =
               compile_rewrite("""
                   tenant :none
                   field :pan,
                     from: Encryptor.Ecto.MigrationTest.PlainTarget,
                     to: Encryptor.Ecto.MigrationTest.PlainTarget
               """)
    end

    # Sabotage: `raise_at!/2` hard-coding "nofile" and 0 - the CompileError
    # pointed nowhere, and a plan of thirty fields gave no line to open.
    test "report the file and line of the offending declaration" do
      error =
        assert_compile_error(fn ->
          compile_rewrite("""
              tenant :none
              field :nope, from: Encryptor.Ecto.TestTypes.Pan, to: Encryptor.Ecto.TestTypes.Pan
          """)
        end)

      assert Exception.message(error) =~ "plan.ex:"
    end
  end
end
