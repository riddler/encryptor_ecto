defmodule Encryptor.Ecto.BlindIndexTest do
  use ExUnit.Case, async: true

  alias Encryptor.Ecto.BlindIndex
  alias Encryptor.Ecto.BlindIndex.Declaration
  alias Encryptor.Ecto.TestSchemas.Customer
  alias Encryptor.Ecto.TestSchemas.Identity

  doctest Encryptor.Ecto.BlindIndex

  # Every schema below is defined inside its test body rather than in
  # `test/support`, for the reason `Encryptor.Ecto.DeclarationsTest` gives:
  # the refusals are compile-time, so a fixture that demonstrates one cannot
  # be compiled with the suite. `defmodule` in a function body defines the
  # module when the test runs, which is where the raise has to be observable.

  describe "the declaration reaches the schema" do
    # sabotage: __before_compile__/1's Enum.reverse/1 applied twice, red - the
    # declarations come back in reverse and every ordered assertion about a
    # host's indexes reports a different set than the host wrote.
    test "a schema carries its indexes in declaration order" do
      assert Customer.__encryptor_ecto_blind_indexes__() |> Enum.map(& &1.column) ==
               [:email_index, :email_short_index, :phone_index]
    end

    # sabotage: the macro's `unquote(opts)` -> `[]`, red (test/support stops
    # compiling: Identity's `scope: :global` is one of the options that stops
    # arriving).
    test "the declared options reach the stored declaration" do
      assert %Declaration{normalize: :digits, slow: true, version: 2, scope: :tenant} =
               Declaration.fetch!(Customer, :phone, :phone_index)
    end

    # sabotage: __before_compile__/1's list -> Enum.take(1), red - only the
    # first declaration survives.
    test "several declarations on one schema all survive" do
      assert length(Declaration.list(Customer)) == 3
    end

    # sabotage: the macro's `unquote(opts)` -> `[]`, red - the written
    # `scope: :global` stops arriving and decision 3c refuses the schema.
    test "a global field declaring scope: :global compiles" do
      assert %Declaration{scope: :global, scope_declared?: true} =
               Declaration.fetch!(Identity, :email, :email_index)
    end
  end

  describe "decision 3c: a tenant: :none field must write its :scope" do
    # sabotage: validate_scope!/2's `scope_declared?: false` clause guarded to
    # match nothing, red. The fallback to :global would be silent, and silence
    # is exactly what the reviewer reading that schema line does not see.
    test "declaring no :scope on a tenant: :none field is a compile error" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule SilentGlobal do
            use Ecto.Schema

            import Encryptor.Ecto.BlindIndex

            schema "silent_globals" do
              field(:email, Encryptor.Ecto.TestTypes.GlobalName)
              field(:email_index, :binary)
              blind_index(:email, :email_index, normalize: :email)
            end
          end
        end

      assert Exception.message(error) =~ "with no :scope"
      assert Exception.message(error) =~ "tenant: :none"
      assert Exception.message(error) =~ "survives a tenant shred"
    end

    # sabotage: validate_scope!/2's `scope: :tenant` clause guarded to match
    # nothing, red. This is open question Q4: a global ciphertext with a
    # per-tenant index is an incoherent pair, and it stays an error until
    # somebody brings the case.
    test "declaring scope: :tenant on a tenant: :none field is a compile error" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule TenantScopedGlobal do
            use Ecto.Schema

            import Encryptor.Ecto.BlindIndex

            schema "tenant_scoped_globals" do
              field(:email, Encryptor.Ecto.TestTypes.GlobalName)
              field(:email_index, :binary)
              blind_index(:email, :email_index, scope: :tenant)
            end
          end
        end

      assert Exception.message(error) =~ "with scope: :tenant"
      assert Exception.message(error) =~ "incoherent pair"
    end

    # sabotage: validate_scope!/2's catch-all clause -> a raise, red
    # (test/support stops compiling). A tenant-capable field defaults to
    # :tenant and writes nothing, which is decision 3a and the overwhelmingly
    # common case.
    test "declaring no :scope on a tenant-capable field is the default, not an error" do
      defmodule DefaultScoped do
        use Ecto.Schema

        import Encryptor.Ecto.BlindIndex

        schema "default_scoped" do
          field(:email, Encryptor.Ecto.TestTypes.HolderName)
          field(:email_index, :binary)
          blind_index(:email, :email_index, normalize: :email)
        end
      end

      assert %Declaration{scope: :tenant} =
               Declaration.fetch!(DefaultScoped, :email, :email_index)
    end
  end

  describe "decision 3c: the source must be a field this package encrypts" do
    # sabotage: source_params!/1's `{:error, :not_encrypted}` arm guarded to
    # match nothing, red. A keyed fingerprint of a column that is already
    # readable protects nothing, and there is no declared context to derive its
    # key from.
    test "an index on an ordinary field is a compile error" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule PlaintextIndexed do
            use Ecto.Schema

            import Encryptor.Ecto.BlindIndex

            schema "plaintext_indexed" do
              field(:email, :string)
              field(:email_index, :binary)
              blind_index(:email, :email_index)
            end
          end
        end

      assert Exception.message(error) =~ "not a field this package encrypts"
    end

    # sabotage: source_params!/1's `{:error, :missing_field}` arm guarded to
    # match nothing, red. The likelier fault - a misspelled field - has to be
    # named accurately or a host goes looking at its type modules.
    test "an index on a field that does not exist is a compile error" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule MisspelledSource do
            use Ecto.Schema

            import Encryptor.Ecto.BlindIndex

            schema "misspelled_sources" do
              field(:email, Encryptor.Ecto.TestTypes.HolderName)
              field(:email_index, :binary)
              blind_index(:emial, :email_index)
            end
          end
        end

      assert Exception.message(error) =~ "is not a field on this schema"
    end

    # The other half of the same predicate: `Encryptor.Ecto.String` and
    # `Encryptor.Ecto.Map` fields are encrypted fields too, and an index on
    # one has to be accepted. (The parallel-compiler half of the predicate -
    # `Code.ensure_compiled/1` rather than `Code.ensure_loaded?/1` - is
    # covered by `test/support/test_index_schemas.ex` compiling at all, where
    # the type modules are in the same compilation unit as the schema. This
    # test defines its schema at runtime, where both spellings agree.)
    #
    # sabotage: Declaration.encrypted?/1's condition -> `and false`, red.
    test "an index on a String or Map field compiles" do
      defmodule EveryShape do
        use Ecto.Schema

        import Encryptor.Ecto.BlindIndex

        schema "every_shape" do
          field(:pan, Encryptor.Ecto.TestTypes.Pan)
          field(:pan_index, :binary)
          blind_index(:pan, :pan_index)

          field(:holder_name, Encryptor.Ecto.TestTypes.HolderName)
          field(:holder_name_index, :binary)
          blind_index(:holder_name, :holder_name_index, normalize: :downcase)

          field(:metadata, Encryptor.Ecto.TestTypes.Metadata)
          field(:metadata_index, :binary)
          blind_index(:metadata, :metadata_index)
        end
      end

      assert length(Declaration.list(EveryShape)) == 3
    end
  end

  describe "declaration hygiene, beyond the record" do
    # sabotage: validate_index_column!/1's subject -> a literal ordinary type,
    # red. Nothing can write a column that is not a field, and without the
    # check the failure arrives at the first write naming Ecto's error rather
    # than the schema.
    test "an index column that is not a field is a compile error" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule NoIndexColumn do
            use Ecto.Schema

            import Encryptor.Ecto.BlindIndex

            schema "no_index_column" do
              field(:email, Encryptor.Ecto.TestTypes.HolderName)
              blind_index(:email, :email_index)
            end
          end
        end

      assert Exception.message(error) =~ ":email_index is not a field on this schema"
    end

    # sabotage: validate_index_column!/1's encrypted_type?/1 condition ->
    # `and false`, red. An encrypted index column is unqueryable, which is the
    # whole point of the column.
    test "an index column that is itself encrypted is a compile error" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule EncryptedIndexColumn do
            use Ecto.Schema

            import Encryptor.Ecto.BlindIndex

            schema "encrypted_index_column" do
              field(:email, Encryptor.Ecto.TestTypes.HolderName)
              field(:email_index, Encryptor.Ecto.TestTypes.Pan)
              blind_index(:email, :email_index)
            end
          end
        end

      assert Exception.message(error) =~ "is itself an encrypted field"
    end

    # sabotage: the validate_distinct!/4 call keyed on `& &1.name` -> :ok, red.
    # Two indexes sharing an index_name derive one key, which is the collapse
    # decision 2's index_name component exists to prevent - and it is silent.
    test "two indexes sharing an index_name are a compile error" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule CollidingNames do
            use Ecto.Schema

            import Encryptor.Ecto.BlindIndex

            schema "colliding_names" do
              field(:email, Encryptor.Ecto.TestTypes.HolderName)
              field(:email_index, :binary)
              field(:email_v2_index, :binary)
              blind_index(:email, :email_index, name: "shared")
              blind_index(:email, :email_v2_index, name: "shared")
            end
          end
        end

      assert Exception.message(error) =~ "sharing an index name"
    end

    # sabotage: the validate_distinct!/4 call keyed on `{source, column}` ->
    # :ok, red. Two declarations writing one column overwrite each other, and
    # which one wins depends on the order the helpers are called in.
    test "two indexes over one {source, column} pair are a compile error" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule DoubledColumn do
            use Ecto.Schema

            import Encryptor.Ecto.BlindIndex

            schema "doubled_column" do
              field(:email, Encryptor.Ecto.TestTypes.HolderName)
              field(:email_index, :binary)
              blind_index(:email, :email_index, name: "one")
              blind_index(:email, :email_index, name: "two")
            end
          end
        end

      assert Exception.message(error) =~ "sharing a source field and column"
    end

    # sabotage: validate_distinct!/4's `length(group) > 1` -> `>= 1`, red
    # (test/support stops compiling). Two legitimate indexes over one field,
    # which is decision 3d's and decision 7's supported shape, must stay
    # legal.
    test "two indexes over one field in different columns are legal" do
      assert Declaration.list(Customer, :email) |> length() == 2
    end
  end

  describe "validate!/1" do
    # sabotage: validate!/1's `declarations == [] or` short-circuit dropped,
    # red. A module with no declarations is not this package's business.
    test "a module that declares nothing passes" do
      assert BlindIndex.validate!(String) == :ok
      assert BlindIndex.validate!(Encryptor.Ecto.TestSchemas.Card) == :ok
    end

    # sabotage: validate!/1's final `:ok` -> `:not_ok`, red.
    test "a schema whose declarations are all sound passes" do
      assert BlindIndex.validate!(Customer) == :ok
      assert BlindIndex.validate!(Identity) == :ok
    end
  end
end
