defmodule Encryptor.Ecto.KeyStoreTest do
  @moduledoc """
  What `Encryptor.Ecto.KeyStore` decides before it has ever seen a row.

  `c:Encryptor.Provider.init/1` runs once, at vault start, and its return is
  frozen into `:persistent_term` for the life of the vault. So every option it
  is going to refuse has to be refused here rather than on the first encrypted
  write, and the refusal terms are the vault's own - a host reading
  `{:missing_config, [:provider, :repo]}` out of a failed start is reading the
  same vocabulary it would get from any other misconfigured provider.

  None of these tests touch a database: that is the claim they are making.
  """

  use ExUnit.Case, async: true

  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.TestGcpKms
  alias Encryptor.Ecto.TestKeyStore
  alias Encryptor.Ecto.TestRepo

  doctest Encryptor.Ecto.KeyStore

  describe "init/1" do
    # Sabotage: made `init/1` return `{:ok, opts}` unchanged. Every option
    # check went away and nothing else in the suite noticed until a query ran
    # against `state.table` and found `nil`, which is the failure this test
    # moves back to start.
    test "resolves a host's options into frozen state" do
      assert {:ok, state} = KeyStore.init(TestKeyStore.provider_opts())

      assert state.repo == TestRepo
      assert state.root_vault == TestKeyStore.Root
      assert state.table == KeyStore.default_table()
      assert byte_size(state.reference_subkey) == 32
    end

    test "takes a table name a host renamed" do
      assert {:ok, state} = KeyStore.init(TestKeyStore.provider_opts(table: "tenant_keys"))

      assert state.table == "tenant_keys"
    end

    test "refuses a missing repo" do
      opts = Keyword.delete(TestKeyStore.provider_opts(), :repo)

      assert {:error, {:missing_config, [:provider, :repo]}} = KeyStore.init(opts)
    end

    test "refuses a missing root vault" do
      opts = Keyword.delete(TestKeyStore.provider_opts(), :root_vault)

      assert {:error, {:missing_config, [:provider, :root_vault]}} = KeyStore.init(opts)
    end

    test "refuses a repo that is not a module" do
      assert {:error, {:invalid_config, :repo, :not_a_module}} =
               KeyStore.init(TestKeyStore.provider_opts(repo: "MyApp.Repo"))
    end

    # Sabotage: dropped the byte-size guard and took any binary. A short
    # subkey then derived a perfectly stable reference that matched no row any
    # correctly configured process had written - a vault that starts, resolves
    # nothing, and reports `:unknown_key` for every tenant it has.
    test "refuses a reference subkey that is not 32 bytes" do
      assert {:error, {:invalid_config, :reference_subkey, :invalid_length}} =
               KeyStore.init(TestKeyStore.provider_opts(reference_subkey: <<1, 2, 3>>))
    end

    test "refuses a missing reference subkey" do
      opts = Keyword.delete(TestKeyStore.provider_opts(), :reference_subkey)

      assert {:error, {:missing_config, [:provider, :reference_subkey]}} = KeyStore.init(opts)
    end

    # Sabotage: accepted any string as a table name. The name is interpolated
    # into a query source rather than bound as a parameter - no adapter
    # parameterizes a table - so the grammar has to be checked somewhere, and
    # start is the only place a host finds out cheaply.
    test "refuses a table name that is not an unquoted identifier" do
      for name <- ["wrapped keys", "Wrapped", "1keys", ~s|keys"; drop table x --|] do
        assert {:error, {:invalid_config, :table, :invalid_name}} =
                 KeyStore.init(TestKeyStore.provider_opts(table: name))
      end
    end

    test "refuses a table that is not a string" do
      assert {:error, {:invalid_config, :table, :invalid_name}} =
               KeyStore.init(TestKeyStore.provider_opts(table: :wrapped_keys))
    end

    test "defaults the schema prefix to the repo's own" do
      assert {:ok, state} = KeyStore.init(TestKeyStore.provider_opts())

      assert state.prefix == nil
    end

    test "takes a schema prefix a host placed the table in" do
      assert {:ok, state} = KeyStore.init(TestKeyStore.provider_opts(prefix: "tenant_keys"))

      assert state.prefix == "tenant_keys"
    end

    # An empty prefix is refused rather than treated as absent: it would read
    # as "the default schema" while saying something was configured, and a
    # host that built the name by interpolation and got it wrong deserves to
    # hear about it at start rather than to silently query the search path.
    test "refuses a prefix that is empty or not a string" do
      for prefix <- ["", :tenant_keys, 42] do
        assert {:error, {:invalid_config, :prefix, :invalid_name}} =
                 KeyStore.init(TestKeyStore.provider_opts(prefix: prefix))
      end
    end
  end

  # Still no database: a `:repo` that is not a repository never gets as far as
  # one. The claim is about what the *rescue* does, and it needs no server.
  describe "init/1's :gcp_kms" do
    test "is absent unless a host names it" do
      assert {:ok, %{gcp_kms: nil}} = KeyStore.init(TestKeyStore.provider_opts())
    end

    # Sabotage: dropped the `Keyword.put/3` of the store's own subkey. The
    # provider's own `init/1` refused the missing `:reference_subkey` at start,
    # so this call answered `{:error, _}` - and the suite did not boot, because
    # the GCP tenant vault `test_helper.exs` starts failed the same way.
    test "resolves with the store's own reference subkey and no store closure" do
      assert {:ok, state} =
               KeyStore.init(TestKeyStore.provider_opts(gcp_kms: TestGcpKms.opts()))

      assert state.gcp_kms[:reference_subkey] == TestKeyStore.reference_subkey()
      refute Keyword.has_key?(state.gcp_kms, :store)
      assert state.gcp_kms[:project] == "test-project"
    end

    # The two options the store supplies are a literal list. Sabotage: removed
    # `:store` from it. The `:store` case resolved, and the host's closure was
    # silently replaced per row.
    test "refuses the two options the store supplies itself" do
      for supplied <- [:reference_subkey, :store] do
        opts = TestKeyStore.provider_opts(gcp_kms: [{supplied, nil} | TestGcpKms.opts()])

        assert {:error, {:invalid_config, :gcp_kms, {:supplied_by_key_store, ^supplied}}} =
                 KeyStore.init(opts)
      end
    end

    test "refuses a value that is not a keyword list" do
      for bad <- [:yes, "project", [1, 2]] do
        assert {:error, {:invalid_config, :gcp_kms, :not_a_keyword_list}} =
                 KeyStore.init(TestKeyStore.provider_opts(gcp_kms: bad))
      end
    end

    # Sabotage: resolved `:gcp_kms` without calling the provider's `init/1`.
    # A client with no project started, and the refusal moved to the first
    # GCP read.
    test "refuses at start what the provider's own init/1 refuses, in its terms" do
      opts = TestKeyStore.provider_opts(gcp_kms: Keyword.delete(TestGcpKms.opts(), :project))

      assert {:error, {:missing_config, [:provider, :project]}} = KeyStore.init(opts)
    end
  end

  describe "a permanent misconfiguration" do
    # Sabotage: put the bare `rescue _exception ->` back. Both calls answered
    # `{:key_unavailable, "merchant_7f3"}` - a reason whose entire meaning is
    # "try again later" - for a provider option that will be wrong on every
    # call until somebody edits the config, with the `UndefinedFunctionError`
    # naming the real mistake dropped on the floor.
    test "a repo that is not a repository raises rather than reporting key_unavailable" do
      state = TestKeyStore.state(repo: __MODULE__.NotARepo)

      assert_raise UndefinedFunctionError, fn ->
        KeyStore.encryption_key(state, "merchant_7f3")
      end

      assert_raise UndefinedFunctionError, fn ->
        KeyStore.decryption_keys(state, "merchant_7f3")
      end
    end
  end

  defmodule NotARepo do
    @moduledoc """
    A module that is a perfectly good module and not a repository.

    `init/1` accepts any atom for `:repo` - it cannot do better, since a repo
    is named at configuration time and started elsewhere - so the mistake
    surfaces at the first query as `UndefinedFunctionError`, which is where
    this test meets it.
    """
  end
end
