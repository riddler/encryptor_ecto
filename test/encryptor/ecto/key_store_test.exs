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
  end
end
