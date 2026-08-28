defmodule Encryptor.Ecto.TestSources do
  @moduledoc """
  The `from:` modules the `Encryptor.Ecto.Migrator.Source` tests resolve and
  call.

  They stand in for a host's own legacy type modules. None of them is a
  `cloak_ecto` type, and that is the point of ADR-0004 decision 2: the adapter
  is defined against the `Ecto.Type` and `Ecto.ParameterizedType` callbacks,
  so the fixtures only have to have the right shape. The reversible "cipher"
  here is `String.reverse/1`, which is emphatically not encryption and is
  never used for anything but proving that the bytes made the round trip.
  """

  defmodule LegacyType do
    @moduledoc "A plain `Ecto.Type` - the shape a `cloak_ecto` type has."

    def type, do: :binary
    def cast(value), do: {:ok, value}
    def dump(value), do: {:ok, value}

    def load("legacy:" <> rest), do: {:ok, String.reverse(rest)}
    def load(_value), do: :error
  end

  defmodule LegacyParameterizedType do
    @moduledoc "An `Ecto.ParameterizedType`, whose params the migrator builds."

    def init(opts), do: Map.new(opts)
    def type(_params), do: :binary
    def cast(value, _params), do: {:ok, value}
    def dump(value, _dumper, _params), do: {:ok, value}

    def load("legacy:" <> rest, loader, params) do
      send(self(), {:loaded_with, params, is_function(loader, 2)})
      {:ok, String.reverse(rest)}
    end

    def load(_value, _loader, _params), do: :error
  end

  defmodule RaisingType do
    @moduledoc "A legacy type that raises rather than returning `:error`."

    defmodule Failure do
      @moduledoc "Carries a value, the way a foreign exception might."
      defexception [:message, :value]
    end

    def type, do: :binary
    def cast(value), do: {:ok, value}
    def dump(value), do: {:ok, value}

    def load(_value), do: raise(Failure, message: "boom", value: "4111111111111111")
  end

  defmodule RaisingParameterizedType do
    @moduledoc "An `Ecto.ParameterizedType` that raises, as its arity-1 sibling does."

    def init(opts), do: Map.new(opts)
    def type(_params), do: :binary
    def cast(value, _params), do: {:ok, value}
    def dump(value, _dumper, _params), do: {:ok, value}

    def load(_value, _loader, _params) do
      raise RaisingType.Failure, message: "boom", value: "4111111111111111"
    end
  end

  defmodule ClosureType do
    @moduledoc "A legacy type that defers its decrypt, as cloak's `:closure` does."

    def type, do: :binary
    def cast(value), do: {:ok, value}
    def dump(value), do: {:ok, value}

    def load("deferred:" <> rest), do: {:ok, fn -> String.reverse(rest) end}
    def load("nested:" <> rest), do: {:ok, fn -> fn -> String.reverse(rest) end end}
    def load("raising:" <> _rest), do: {:ok, fn -> raise RaisingType.Failure, message: "boom" end}
    def load(_value), do: :error
  end

  defmodule MisbehavingType do
    @moduledoc "A legacy type returning a shape neither Ecto nor this package expects."

    def type, do: :binary
    def cast(value), do: {:ok, value}
    def dump(value), do: {:ok, value}

    def load(_value), do: "4111111111111111"
  end

  defmodule ThrowingType do
    @moduledoc "A legacy type that throws, which is misbehaviour rather than a failed decrypt."

    def type, do: :binary
    def cast(value), do: {:ok, value}
    def dump(value), do: {:ok, value}

    def load(_value), do: throw(:no)
  end

  defmodule TupleErrorType do
    @moduledoc "A hand-rolled type that returns a reason instead of a bare `:error`."

    def type, do: :binary
    def cast(value), do: {:ok, value}
    def dump(value), do: {:ok, value}

    def load(_value), do: {:error, :wrong_key}
  end

  defmodule DirectSource do
    @moduledoc "A module implementing the behaviour itself, used as-is."

    @behaviour Encryptor.Ecto.Migrator.Source

    @impl true
    def load("direct:" <> rest, params) do
      send(self(), {:direct_params, params})
      {:ok, String.reverse(rest)}
    end

    def load(_value, _params), do: {:error, :unreadable}
  end

  defmodule MisbehavingSource do
    @moduledoc "A direct source returning a shape the behaviour does not allow."

    @behaviour Encryptor.Ecto.Migrator.Source

    @impl true
    def load(_value, _params), do: "4111111111111111"
  end

  defmodule DirectSourceAlsoEctoType do
    @moduledoc "Implements the behaviour *and* exports `load/1`; the behaviour wins."

    @behaviour Encryptor.Ecto.Migrator.Source

    def load(_value), do: {:ok, "via ecto type"}

    @impl true
    def load(_value, _params), do: {:ok, "via source"}
  end

  defmodule NotASource do
    @moduledoc "Reads nothing: no `load/1`, no `load/3`, not a source."

    def type, do: :binary
  end
end
