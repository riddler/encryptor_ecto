# The vaults the type tests encrypt through are started for every arm,
# database or not: they resolve offline from static material and have nothing
# to do with Postgres.
for vault <- [
      Encryptor.Ecto.TestVaults.Merchant,
      Encryptor.Ecto.TestVaults.MerchantRekeyed,
      Encryptor.Ecto.TestVaults.MerchantSigned,
      Encryptor.Ecto.TestVaults.MerchantStatic,
      Encryptor.Ecto.TestVaults.App,
      Encryptor.Ecto.TestVaults.Strict,
      Encryptor.Ecto.TestVaults.Unsalted,
      Encryptor.Ecto.TestVaults.OtherDeployment,
      # The wrapped-key store's own pair. Neither `init/1` touches a database -
      # the store-backed provider resolves configuration and nothing else at
      # start - so both start on this arm too, and the tests that read rows
      # carry `:database` themselves.
      Encryptor.Ecto.TestKeyStore.Root,
      Encryptor.Ecto.TestKeyStore.Tenant
    ] do
  {:ok, _pid} = vault.start_link()
end

case Encryptor.Ecto.TestDatabase.exunit_options() do
  {:ok, []} ->
    # The repository is started only on this arm. Starting it when nothing is
    # listening would turn the legible skip below into a connection error at
    # boot, which is the failure this whole arrangement exists to avoid.
    :ok = Encryptor.Ecto.TestRepo.setup!()
    ExUnit.start()

  {:ok, options} ->
    IO.puts(:stderr, Encryptor.Ecto.TestDatabase.skip_message())
    ExUnit.start(options)

  {:error, message} ->
    IO.puts(:stderr, message)
    System.halt(1)
end
