# The vaults the type tests encrypt through are started for every arm,
# database or not: they resolve offline from static material and have nothing
# to do with Postgres.
for vault <- [
      Encryptor.Ecto.TestVaults.Merchant,
      Encryptor.Ecto.TestVaults.App,
      Encryptor.Ecto.TestVaults.Strict
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
