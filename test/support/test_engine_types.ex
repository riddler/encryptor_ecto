defmodule Encryptor.Ecto.TestEngineTypes do
  @moduledoc """
  Types that let a test stand in the way of the engine's compare-and-swap.

  ADR-0002 decision 4's property is about a row the application rewrites
  *between* the migrator's read and its write, and a suite that only ever runs
  the migrator alone never observes it. These types run a test-supplied
  function in the middle of `dump/3`, which is the exact window: the row has
  been read and probed, the plaintext is in hand, and the update has not been
  issued.

  The hook is a zero-arity function in the process dictionary rather than a
  second process, because the sandbox gives a test one connection: a genuinely
  concurrent writer would be a second connection outside the transaction, and
  its write would be invisible to the query the CAS runs. Same window, same
  outcome, one connection.
  """

  @hook :encryptor_ecto_test_race

  @doc """
  Installs the hook that runs inside the next `dump/3`, once.

  The key is deleted before the function runs, so a hook that writes through
  the same type cannot re-enter itself.
  """
  @spec race_once((-> any())) :: :ok
  def race_once(fun) when is_function(fun, 0) do
    _previous = Process.put(@hook, fun)
    :ok
  end

  @doc false
  @spec run_hook() :: :ok
  def run_hook do
    case Process.delete(@hook) do
      nil -> :ok
      fun -> _ignored = fun.()
    end

    :ok
  end

  defmodule PlainTarget do
    @moduledoc """
    A plain `Ecto.Type` as a plan's `to:` - the arity-1 half of the target
    contract.

    A target does not have to be one of this package's types: ADR-0002
    decision 3 has the migrator call `load` and `dump` through the behaviour,
    and decision 8's adoption path is written in terms of whatever the host
    can already write. The "encryption" here is a `"plain:"` prefix, which is
    exactly as much cryptography as this fixture needs.
    """

    @doc false
    def type, do: :binary

    @doc false
    def cast(value), do: {:ok, value}

    @doc false
    def dump(value) when is_binary(value), do: {:ok, "plain:" <> value}
    def dump(_value), do: :error

    @doc false
    def load("plain:" <> rest), do: {:ok, rest}
    def load(_value), do: :error
  end

  defmodule DecliningTarget do
    @moduledoc "A target that refuses to write, so the dump failure arm has a subject."

    @doc false
    def type, do: :binary

    @doc false
    def cast(value), do: {:ok, value}

    @doc false
    def dump(_value), do: :error

    @doc false
    def load(_value), do: :error
  end

  defmodule RacingPan do
    @moduledoc """
    `Encryptor.Ecto.TestTypes.Pan`, with a window held open inside `dump/3`.

    Every callback delegates, including the marker the migrator recognises an
    encrypted type by - the point of the fixture is that it is the ordinary
    type plus a hook, so anything the engine concludes about it is a
    conclusion about the ordinary type.
    """

    @behaviour Ecto.ParameterizedType

    alias Encryptor.Ecto.TestEngineTypes
    alias Encryptor.Ecto.TestTypes.Pan

    @doc false
    def __encryptor_ecto__(:impl), do: Encryptor.Ecto.Binary

    @doc false
    @impl Ecto.ParameterizedType
    def init(opts), do: Pan.init(opts)

    @doc false
    @impl Ecto.ParameterizedType
    def type(params), do: Pan.type(params)

    @doc false
    @impl Ecto.ParameterizedType
    def cast(value, params), do: Pan.cast(value, params)

    @doc false
    @impl Ecto.ParameterizedType
    def load(value, loader, params), do: Pan.load(value, loader, params)

    @doc false
    @impl Ecto.ParameterizedType
    def dump(value, dumper, params) do
      :ok = TestEngineTypes.run_hook()
      Pan.dump(value, dumper, params)
    end

    @doc false
    @impl Ecto.ParameterizedType
    def equal?(left, right, params), do: Pan.equal?(left, right, params)

    @doc false
    @impl Ecto.ParameterizedType
    def embed_as(format, params), do: Pan.embed_as(format, params)
  end
end
