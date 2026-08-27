defmodule Encryptor.Ecto.TestDatabase do
  @moduledoc """
  Decides whether the database-backed tests run in this suite.

  Some of what the migrator promises is not expressible against a mock repo:
  compare-and-swap against a concurrent writer, keyset resume across a killed
  process, and the probe classifying an already-migrated row all need real
  rows. Those tests carry `@tag :database`, and this module is what keeps them
  out of the ordinary unit run so the inner loop stays fast for a developer
  with no Postgres running.

  Two rules, and the second is the one that matters:

    * with no database reachable, `:database` is excluded and the suite is
      green - a developer gets a legible skip, never a red gate they cannot
      explain;
    * with `ECTO_REQUIRE_DATABASE` set, an unreachable database is a failure
      instead. CI sets it, because a workflow that lost its service container
      would otherwise go green while running none of the tests the container
      exists to run.

  The reachability probe is a TCP connect rather than a driver handshake on
  purpose. This package depends on Ecto and the vault and nothing else, and a
  driver added only to answer "is anything listening" would be a dependency
  the library does not otherwise need. The connection is described entirely by
  the standard `PGHOST`/`PGPORT` variables, so CI and a developer's shell
  configure it the same way.
  """

  @default_host "localhost"
  @default_port 5432
  @connect_timeout 2_000

  @falsey ["", "0", "false"]

  @doc "The host the database-backed tests expect Postgres on."
  @spec host() :: String.t()
  def host, do: System.get_env("PGHOST", @default_host)

  @doc "The port the database-backed tests expect Postgres on."
  @spec port() :: pos_integer()
  def port do
    case System.get_env("PGPORT") do
      nil -> @default_port
      value -> String.to_integer(value)
    end
  end

  @doc """
  Whether an unreachable database is a failure rather than a skip.

  True when `ECTO_REQUIRE_DATABASE` is set to anything but an empty string,
  `0`, or `false`.
  """
  @spec required?() :: boolean()
  def required? do
    System.get_env("ECTO_REQUIRE_DATABASE") not in [nil | @falsey]
  end

  @doc """
  Whether something accepts connections at `host/0` and `port/0`.

  A TCP connect proves a server is listening, which is all this needs to
  decide between running the database-backed tests and skipping them.
  """
  @spec reachable?() :: boolean()
  def reachable? do
    address = String.to_charlist(host())

    case :gen_tcp.connect(address, port(), [:binary, active: false], @connect_timeout) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  @doc """
  The options `ExUnit.start/1` should be given, or the reason it must not run.

  Returns `{:ok, []}` when the database is reachable, `{:ok, exclude:
  [:database]}` when it is not and is not required, and `{:error, message}`
  when it is not reachable and `ECTO_REQUIRE_DATABASE` says it had to be.
  """
  @spec exunit_options() :: {:ok, keyword()} | {:error, String.t()}
  def exunit_options do
    cond do
      reachable?() -> {:ok, []}
      required?() -> {:error, required_message()}
      true -> {:ok, [exclude: [:database]]}
    end
  end

  @doc "The line printed when the database-backed tests are skipped."
  @spec skip_message() :: String.t()
  def skip_message do
    "No Postgres at #{endpoint()} - excluding tests tagged :database. " <>
      "Start one, or set PGHOST/PGPORT, to run them."
  end

  defp required_message do
    "ECTO_REQUIRE_DATABASE is set but no Postgres answers at #{endpoint()}. " <>
      "Refusing to run: skipping the :database tests here would report a " <>
      "green suite that exercised none of them."
  end

  defp endpoint, do: "#{host()}:#{port()}"
end
