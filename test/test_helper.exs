case Encryptor.Ecto.TestDatabase.exunit_options() do
  {:ok, []} ->
    ExUnit.start()

  {:ok, options} ->
    IO.puts(:stderr, Encryptor.Ecto.TestDatabase.skip_message())
    ExUnit.start(options)

  {:error, message} ->
    IO.puts(:stderr, message)
    System.halt(1)
end
