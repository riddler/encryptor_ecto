defmodule Encryptor.Ecto.BlindIndex.DeclarationTest do
  use ExUnit.Case, async: true

  alias Encryptor.Ecto.BlindIndex.Declaration
  alias Encryptor.Ecto.BlindIndex.Derivation
  alias Encryptor.Ecto.BlindIndex.NormalizationError
  alias Encryptor.Ecto.MissingTenantError
  alias Encryptor.Ecto.Tenant
  alias Encryptor.Ecto.TestNormalizers
  alias Encryptor.Ecto.TestSchemas.Customer
  alias Encryptor.Ecto.TestSchemas.Identity
  alias Encryptor.Ecto.TestVaults

  doctest Encryptor.Ecto.BlindIndex.Declaration

  defp new!(opts \\ []), do: Declaration.new!(MyApp.Customer, :email, :email_index, opts)

  describe "new!/4 defaults" do
    # sabotage: new!/4's `scope: Keyword.get(opts, :scope, :tenant)` -> :global,
    # red. Decision 3a's default is per-tenant, and a default that silently
    # went the other way would make every unwritten index cross-tenant
    # correlatable.
    test "an index with no options is per-tenant, byte-exact, full width, version 1" do
      assert %Declaration{
               scope: :tenant,
               scope_declared?: false,
               normalize: :none,
               bits: 256,
               slow: false,
               version: 1,
               name: "email_index"
             } = new!()
    end

    # sabotage: name!/3's default `column` -> `source`, red (test/support
    # stops compiling: Customer's two indexes over :email collapse onto one
    # name and the duplicate check refuses the schema, which is exactly the
    # collapse this reading of decision 6's ambiguous "the column name"
    # exists to prevent).
    test "the index_name defaults to the index column, so two indexes over one field differ" do
      first = Declaration.new!(MyApp.Customer, :email, :email_index)
      second = Declaration.new!(MyApp.Customer, :email, :email_v2_index)

      assert first.name == "email_index"
      assert second.name == "email_v2_index"
      refute first.name == second.name
    end

    # sabotage: new!/4's `scope_declared?: Keyword.has_key?(...)` -> false, red
    # (test/support stops compiling: Identity's written `scope: :global` stops
    # counting as written and decision 3c refuses it). `scope: :global` written
    # and `scope: :global` inferred are the same derivation and a different
    # schema line, and decision 3c cares about the line.
    test "scope_declared? records whether the reviewer saw :scope written" do
      assert new!(scope: :tenant).scope_declared?
      assert new!(scope: :global).scope_declared?
      refute new!().scope_declared?
    end

    # sabotage: name!/3's atom arm guarded to match nothing, red (test/support
    # stops compiling: the default name is the column *atom*, so every
    # declaration that writes no :name goes through this arm).
    test "a :name given as an atom becomes the binary the info string needs" do
      assert new!(name: :legacy_email).name == "legacy_email"
      assert new!(name: "legacy_email").name == "legacy_email"
    end
  end

  describe "new!/4 refusals" do
    # sabotage: validate_options!/2's `Keyword.keys(opts) -- @options` -> `[]`,
    # red. A misspelled :normalize would silently index the raw plaintext under
    # a declaration that says it does not.
    test "an unknown option is refused where it is written" do
      assert_raise ArgumentError, ~r/unknown options: \[:normalise\]/, fn ->
        new!(normalise: :email)
      end
    end

    # sabotage: validate_option!/2's :scope guard widened to admit it, red.
    test "a :scope outside the set is refused" do
      assert_raise ArgumentError, ~r/:scope: :per_tenant, which is not one of/, fn ->
        new!(scope: :per_tenant)
      end
    end

    # sabotage: validate_option!/2's :bits guard widened to admit 96, red. It is
    # not a width decision 6 offers, and a declaration carrying it would look
    # honoured until ece-6a6 lands and refused it.
    test "a :bits outside the set is refused" do
      assert_raise ArgumentError, ~r/:bits: 96, which is not one of/, fn ->
        new!(bits: 96)
      end
    end

    # sabotage: validate_option!/2's `Normalizer.valid?/1` condition -> true, red.
    test "a normalizer outside the set is refused" do
      assert_raise ArgumentError, ~r/:normalize: :uppercase/, fn ->
        new!(normalize: :uppercase)
      end
    end

    # sabotage: validate_option!/2's version condition -> true, red. Version 0
    # or a negative one would derive a real key under a version decision 7's
    # rotation sequence cannot reach.
    test "a version that is not a positive integer is refused" do
      for version <- [0, -1, "2", 1.0] do
        assert_raise ArgumentError, ~r/:version:/, fn -> new!(version: version) end
      end
    end

    # sabotage: validate_option!/2's :slow guard -> `not is_atom(slow)`, red.
    test "a :slow that is not a boolean is refused" do
      assert_raise ArgumentError, ~r/:slow: :yes, which is not a boolean/, fn ->
        new!(slow: :yes)
      end
    end

    # sabotage: name!/3's String.contains?/2 needle -> a NUL byte, red. A name that
    # can spell the info string's separator can spell a different index's
    # identity from a different starting point, which collapses two keys the
    # design keeps apart. Derivation refuses it too; this catches it where the
    # host wrote it.
    test "a :name carrying the info string's separator is refused" do
      assert_raise ArgumentError, ~r/:name: "a\|b"/, fn -> new!(name: "a|b") end
    end

    # sabotage: name!/3's `name != ""` conjunct dropped, red.
    test "an empty or absent :name is refused" do
      for name <- ["", nil, true, 7] do
        assert_raise ArgumentError, ~r/:name:/, fn -> new!(name: name) end
      end
    end

    # sabotage: validate_options!/2's Keyword.keyword?/1 condition -> `or true`, red.
    test "options that are not a keyword list are refused" do
      assert_raise ArgumentError, ~r/expects a keyword list/, fn -> new!(%{normalize: :email}) end
    end

    # sabotage: new!/4's is_atom/1 condition -> `or true`, red.
    test "a source or column that is not an atom is refused" do
      assert_raise ArgumentError, ~r/must both be atoms/, fn ->
        Declaration.new!(MyApp.Customer, "email", :email_index)
      end
    end
  end

  describe "reading a schema" do
    # sabotage: list/1's declares?/1 condition -> `and false`, red.
    test "list/1 returns a schema's indexes in declaration order" do
      assert Declaration.list(Customer) |> Enum.map(& &1.name) ==
               ["email_index", "email_short_index", "phone_index"]
    end

    # sabotage: declares?/1's function_exported?/2 half -> true, red. A module
    # that declares nothing must answer "no indexes" rather than crash a caller
    # sweeping a host's modules.
    test "a module with no declarations has none rather than an error" do
      assert Declaration.list(Encryptor.Ecto.TestSchemas.Card) == []
      assert Declaration.list(String) == []
      assert Declaration.list(NoSuchModuleAnywhere) == []
    end

    # sabotage: list/2's Enum.filter/2 dropped, red.
    test "list/2 narrows to one source field" do
      assert Declaration.list(Customer, :phone) |> Enum.map(& &1.column) == [:phone_index]
      assert Declaration.list(Customer, :nothing) == []
    end

    # sabotage: fetch/3's `&1.column == column` conjunct dropped, red - the
    # first index over the field would answer for every column, and the narrow
    # index would silently be computed at full width.
    test "fetch/3 resolves one {source, column} pair" do
      assert {:ok, %Declaration{bits: 64}} =
               Declaration.fetch(Customer, :email, :email_short_index)

      assert {:ok, %Declaration{bits: 256}} = Declaration.fetch(Customer, :email, :email_index)
      assert Declaration.fetch(Customer, :email, :nowhere) == :error
    end

    # sabotage: fetch!/3's :error arm -> nil, red.
    test "fetch!/3 names what is declared when nothing matches" do
      error = assert_raise ArgumentError, fn -> Declaration.fetch!(Customer, :email, :nowhere) end

      assert Exception.message(error) =~ "declares no blind index"
      assert Exception.message(error) =~ "blind_index :email, :email_index"
    end

    # sabotage: declared_list/1's [] arm -> "", red.
    test "fetch!/3 says so plainly when a schema declares nothing at all" do
      error =
        assert_raise ArgumentError, fn ->
          Declaration.fetch!(Encryptor.Ecto.TestSchemas.Card, :pan, :pan_index)
        end

      assert Exception.message(error) =~ "(none)"
    end
  end

  describe "resolving against the encrypted field" do
    # sabotage: field_params/1's encrypted?/1 condition -> `and false`, red
    # (test/support stops compiling: every declaration's source stops
    # resolving).
    test "field_params!/1 reads the frozen declared context, not the schema's source" do
      params =
        Customer
        |> Declaration.fetch!(:email, :email_index)
        |> Declaration.field_params!()

      assert %{table: "customers", column: "email", tenant: :scope} = params
    end

    # sabotage: derivation!/1's `column: params.column` -> the declaration's
    # index column, red. The derivation must key under the *encrypted field's*
    # declared context, which is what ties an index to the column it indexes
    # rather than to the column it is stored in.
    test "derivation!/1 keys under the encrypted field's declared table and column" do
      derivation =
        Customer
        |> Declaration.fetch!(:email, :email_index)
        |> Declaration.derivation!()

      assert %Derivation{table: "customers", column: "email", scope: :tenant} = derivation
      assert Derivation.info(derivation) =~ "|customers|email|email_index|1"
    end

    # sabotage: derivation!/1's `index_name` -> `params.column`, red. Two
    # indexes over one field deriving one key is the collapse decision 2's
    # index_name component exists to prevent, and it is silent: both columns
    # would hold the same bytes.
    test "two indexes over one field derive under different info strings" do
      full = Customer |> Declaration.fetch!(:email, :email_index) |> Declaration.derivation!()

      short =
        Customer |> Declaration.fetch!(:email, :email_short_index) |> Declaration.derivation!()

      refute Derivation.info(full) == Derivation.info(short)
    end

    # sabotage: derivation!/1's `version: declaration.version` -> 1, red.
    # Without it decision 7's rotation recomputes the new column to
    # byte-identical values and rotates nothing while reporting that it had.
    test "a declared :version reaches the derivation" do
      derivation =
        Customer |> Declaration.fetch!(:phone, :phone_index) |> Declaration.derivation!()

      assert derivation.version == 2
      assert Derivation.info(derivation) =~ "|phone_index|2"
    end

    # sabotage: derivation!/1's `scope: declaration.scope` -> :tenant, red. A
    # global index whose derivation asked for a tenant would raise on the
    # cross-tenant login path, which is the one path per-tenant cannot serve.
    test "a global declaration derives with the global selector" do
      declaration = Declaration.fetch!(Identity, :email, :email_index)
      derivation = Declaration.derivation!(declaration)
      params = Declaration.field_params!(declaration)

      assert derivation.scope == :global
      assert Derivation.selector!(derivation, params, :dump) == :global
    end

    # sabotage: normalize!/2's `declaration.normalize` -> :none, red. The write
    # side and the read side reading one declaration is decision 5's whole
    # claim, and a helper that normalized differently would find nothing while
    # looking exactly like an absent row.
    test "normalize!/2 applies the declared normalizer" do
      declaration = Declaration.fetch!(Customer, :email, :email_index)

      assert Declaration.normalize!(declaration, " Bob@Example.COM ") == "bob@example.com"
    end

    # sabotage: normalize!/2's `index_name` context -> nil, red. A failure
    # naming no index leaves a host grepping its schemas for the normalizer.
    test "a host normalizer's failure names the encrypted field, not the call site" do
      declaration = %Declaration{
        Declaration.fetch!(Customer, :email, :email_index)
        | normalize: {TestNormalizers, :raising}
      }

      error =
        assert_raise NormalizationError, fn ->
          Declaration.normalize!(declaration, "4111111111111111")
        end

      assert error.table == "customers"
      assert error.column == "email"
      assert error.index_name == "email_index"
    end

    # sabotage: field_params!/1's `{:error, reason}` arm -> `%{}`, red.
    test "a declaration whose source is not an encrypted field cannot resolve" do
      declaration = %Declaration{
        Declaration.fetch!(Customer, :email, :email_index)
        | source: :merchant_id
      }

      assert Declaration.field_params(declaration) == {:error, :not_encrypted}

      assert_raise ArgumentError, ~r/not a field this package encrypts/, fn ->
        Declaration.field_params!(declaration)
      end
    end

    # sabotage: field_params/1's nil arm -> `{:error, :not_encrypted}`, red. The
    # two messages send a host to different places, and the likelier fault - a
    # misspelled field - is the one that has to be named accurately.
    test "a declaration whose source is no field at all says so" do
      declaration = %Declaration{
        Declaration.fetch!(Customer, :email, :email_index)
        | source: :no_such_field
      }

      assert Declaration.field_params(declaration) == {:error, :missing_field}

      assert_raise ArgumentError, ~r/is not a field on that schema/, fn ->
        Declaration.field_params!(declaration)
      end
    end
  end

  describe "the declaration composes into an index value" do
    # Nothing in this bead computes index values - that is `ece-8cn`'s
    # `put_index/3` and `where_eq/3`. What these tests assert is that the three
    # pieces this bead does own compose into one: the declaration resolves to a
    # derivation, the derivation derives a real key through a real vault, and
    # the normalizer decides what that key is applied to. A host holding only
    # this surface can already compute the value, which is what makes the
    # helpers a convenience rather than the mechanism.
    defp index_value(schema, source, column, plaintext) do
      declaration = Declaration.fetch!(schema, source, column)
      derivation = Declaration.derivation!(declaration)
      params = Declaration.field_params!(declaration)
      selector = Derivation.selector!(derivation, params, :dump)

      {:ok, key} = Derivation.derive(TestVaults.Merchant, derivation, selector)

      :crypto.mac(:hmac, :sha256, key, Declaration.normalize!(declaration, plaintext))
    end

    # sabotage: Declaration.normalize!/2's `declaration.normalize` -> :none, red.
    # Normalization being lossy and directional is the property the write side
    # and the read side have to agree on, and they agree by reading one
    # declaration.
    test "normalization decides what the HMAC is computed over" do
      Tenant.wrap("merchant_7f3", fn ->
        padded = index_value(Customer, :email, :email_index, " Bob@Example.COM ")
        bare = index_value(Customer, :email, :email_index, "bob@example.com")

        assert byte_size(padded) == 32
        assert padded == bare
      end)
    end

    # sabotage: Declaration.derivation!/1's `index_name` -> `params.column`, red.
    # Decision 2's index_name component: two indexes over one column must not
    # produce the same bytes, and the failure is silent - both columns would
    # simply hold the same value.
    test "two indexes over one field produce unrelated bytes" do
      Tenant.wrap("merchant_7f3", fn ->
        full = index_value(Customer, :email, :email_index, "bob@example.com")
        short = index_value(Customer, :email, :email_short_index, "bob@example.com")

        refute full == short
      end)
    end

    # ADR-0003 decision 3b's cross-tenant non-correlatability, end to end: two
    # tenants storing one email address must not put the same bytes in the
    # index column, or anyone holding a dump learns they share a customer.
    #
    # sabotage: Declaration.derivation!/1's `scope: declaration.scope` ->
    # :global, red.
    test "the same plaintext in two tenants produces unrelated bytes" do
      a =
        Tenant.wrap("merchant_7f3", fn ->
          index_value(Customer, :email, :email_index, "bob@example.com")
        end)

      b =
        Tenant.wrap("merchant_a19", fn ->
          index_value(Customer, :email, :email_index, "bob@example.com")
        end)

      refute a == b
    end

    # ADR-0003 decision 5, and ADR-0001 decision 5c behind it: a blind-index
    # computation outside tenant scope raises rather than answering. A query
    # that silently matches nothing is the single worst failure this feature
    # can have, because it looks exactly like "the record does not exist".
    #
    # sabotage: Derivation.selector!/3's `{:error, reason}` arm ->
    # `{:tenant, "default"}`, red (that raise is Derivation's, and this is the
    # test that says this surface inherits it rather than working around it).
    test "computing an index value outside tenant scope raises" do
      assert_raise MissingTenantError, fn ->
        index_value(Customer, :email, :email_index, "bob@example.com")
      end
    end
  end
end
