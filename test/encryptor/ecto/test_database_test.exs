defmodule Encryptor.Ecto.TestDatabaseTest do
  # async: false - every test here rewrites process-global environment
  # variables that the module under test reads.
  use ExUnit.Case, async: false

  alias Encryptor.Ecto.TestDatabase

  @vars ["PGHOST", "PGPORT", "ECTO_REQUIRE_DATABASE"]

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  describe "host/0 and port/0" do
    # sabotage: @default_port 5432 -> 5433, red.
    test "default to the conventional local Postgres endpoint" do
      System.delete_env("PGHOST")
      System.delete_env("PGPORT")

      assert TestDatabase.host() == "localhost"
      assert TestDatabase.port() == 5432
    end

    # sabotage: host/0 -> @default_host, ignoring PGHOST, red.
    test "are read from PGHOST and PGPORT when set" do
      System.put_env("PGHOST", "db.example")
      System.put_env("PGPORT", "6543")

      assert TestDatabase.host() == "db.example"
      assert TestDatabase.port() == 6543
    end
  end

  describe "required?/0" do
    # sabotage: @falsey ["", "0", "false"] -> [""], red.
    test "is false when ECTO_REQUIRE_DATABASE is unset or says no" do
      System.delete_env("ECTO_REQUIRE_DATABASE")
      refute TestDatabase.required?()

      for value <- ["", "0", "false"] do
        System.put_env("ECTO_REQUIRE_DATABASE", value)
        refute TestDatabase.required?()
      end
    end

    # sabotage: required?/0 -> always false, red.
    test "is true for any other value" do
      for value <- ["1", "true", "yes"] do
        System.put_env("ECTO_REQUIRE_DATABASE", value)
        assert TestDatabase.required?()
      end
    end
  end

  describe "reachable?/0" do
    # sabotage: the :gen_tcp.connect case scrutinee -> {:error, :sabotage}, red.
    test "is true when something accepts connections on the endpoint" do
      {port, listener} = open_listener()
      on_exit(fn -> :gen_tcp.close(listener) end)

      System.put_env("PGHOST", "localhost")
      System.put_env("PGPORT", Integer.to_string(port))

      assert TestDatabase.reachable?()
    end

    # sabotage: the connect error arm -> true, red.
    test "is false when nothing does" do
      System.put_env("PGHOST", "localhost")
      System.put_env("PGPORT", Integer.to_string(closed_port()))

      refute TestDatabase.reachable?()
    end
  end

  describe "exunit_options/0" do
    # sabotage: the same connect scrutinee -> {:error, :sabotage}, red.
    test "runs everything when the database is reachable" do
      {port, listener} = open_listener()
      on_exit(fn -> :gen_tcp.close(listener) end)

      System.put_env("PGHOST", "localhost")
      System.put_env("PGPORT", Integer.to_string(port))

      assert TestDatabase.exunit_options() == {:ok, []}
    end

    # sabotage: the same error arm -> true, red.
    test "excludes :database when nothing is listening and none is required" do
      System.delete_env("ECTO_REQUIRE_DATABASE")
      System.put_env("PGHOST", "localhost")
      System.put_env("PGPORT", Integer.to_string(closed_port()))

      assert TestDatabase.exunit_options() == {:ok, [exclude: [:database]]}
    end

    # sabotage: required_message() -> "nope", red.
    test "refuses to run when a required database is unreachable" do
      System.put_env("ECTO_REQUIRE_DATABASE", "1")
      System.put_env("PGHOST", "localhost")
      System.put_env("PGPORT", Integer.to_string(closed_port()))

      assert {:error, message} = TestDatabase.exunit_options()
      assert message =~ "ECTO_REQUIRE_DATABASE"
      assert message =~ "Refusing to run"
    end
  end

  # The positive control for the whole arrangement: this test runs only when
  # the :database tag is included, which only happens when a server answered
  # the probe. In CI, where ECTO_REQUIRE_DATABASE is set, a lost service
  # container fails the run rather than silently skipping it.
  @tag :database
  test "the :database tag runs only against a real server" do
    assert TestDatabase.reachable?()
  end

  defp open_listener do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(listener)
    {port, listener}
  end

  # A port that was bound and released, so nothing is listening on it now.
  defp closed_port do
    {port, listener} = open_listener()
    :ok = :gen_tcp.close(listener)
    port
  end
end
