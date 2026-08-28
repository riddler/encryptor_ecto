defmodule Encryptor.Ecto.TestLegacy do
  @moduledoc """
  Stand-ins for the type modules a host was reading a column with before.

  The migration window's whole point is that this package never learns what
  the prior scheme's bytes look like (ADR-0004 decision 1): the module doing
  the legacy load is the host's, with the host's configuration and the host's
  own test suite behind it, and this package's correctness obligation on that
  format is nil. So these fixtures are a *format* stand-in and not an
  encryption scheme - there is no cipher here and no key material, only an
  envelope shaped the way cloak's is (its C3: a reserved `0x01` byte, a length
  byte, then a tag) so that bytes written by one reader are recognisably not
  the other's.

  What is being tested is the fallback's order, its trigger conditions, which
  error survives, and what never reaches a failure message. None of those is a
  claim about cryptography, and a fixture that encrypted would only make the
  suite slower and the assertions harder to read.
  """

  defmodule Format do
    @moduledoc "The envelope the fixtures below read and the tests write."

    @doc """
    Wraps a value in the legacy envelope.

        iex> Encryptor.Ecto.TestLegacy.Format.encode("x")
        <<0x01, 3, "LGC", "x">>
    """
    @spec encode(binary()) :: binary()
    def encode(value) when is_binary(value), do: <<0x01, 3, "LGC">> <> value

    @doc """
    Unwraps one, and refuses anything that is not one.

        iex> Encryptor.Ecto.TestLegacy.Format.decode(<<0x01, 3, "LGC", "x">>)
        {:ok, "x"}

        iex> Encryptor.Ecto.TestLegacy.Format.decode("not the legacy envelope")
        :error
    """
    @spec decode(binary()) :: {:ok, binary()} | :error
    def decode(<<0x01, 3, "LGC", value::binary>>), do: {:ok, value}
    def decode(_bytes), do: :error
  end

  defmodule Binary do
    @moduledoc "The ordinary case: an `Ecto.Type`-shaped reader of the old format."

    @doc "Reads a legacy envelope, and declines anything else the way `Ecto.Type` does."
    @spec load(binary()) :: {:ok, binary()} | :error
    def load(bytes), do: Format.decode(bytes)
  end

  defmodule Anything do
    @moduledoc """
    A reader that answers every call, whatever it is given.

    ADR-0004 decision 4a's two prohibitions - no fallback for a missing tenant,
    none for a missing context key - are only testable against a legacy module
    that *would* have succeeded. A fixture that declines cannot tell "was
    never asked" apart from "was asked and could not answer".
    """

    @doc "Always answers, with a value no other fixture produces."
    @spec load(binary()) :: {:ok, binary()}
    def load(_bytes), do: {:ok, "the legacy reader should not have been asked"}
  end

  defmodule Deferred do
    @moduledoc """
    A reader that defers the decryption, the way cloak's `closure: true` does.

    Returns a zero-arity function rather than the value (ADR-0004's C10), so
    the unwrap the type performs has a subject.
    """

    @doc "Answers with a function that produces the value when called."
    @spec load(binary()) :: {:ok, (-> binary())} | :error
    def load(bytes) do
      case Format.decode(bytes) do
        {:ok, value} -> {:ok, fn -> value end}
        :error -> :error
      end
    end
  end

  defmodule Raising do
    @moduledoc """
    A reader that raises, with the stored bytes in its own message.

    Legacy error structs really do carry the payload they choked on, so this
    fixture carries one too: the assertion that matters is that none of it
    reaches the exception a host sees.
    """

    @doc "Always raises, and puts the bytes it was given in the message."
    @spec load(binary()) :: no_return()
    def load(bytes), do: raise(ArgumentError, "the legacy reader choked on #{inspect(bytes)}")
  end

  defmodule OffContract do
    @moduledoc "A reader answering outside `Ecto.Type`'s contract."

    @doc "Returns a bare value rather than a result."
    def load(_bytes), do: :whatever
  end

  defmodule Map do
    @moduledoc """
    A map-typed reader: it returns the map, not bytes to deserialize.

    Which is what a legacy map type is - cloak's own is its binary type plus a
    decode - and the reason `Encryptor.Ecto.Map` must not run its serializer
    over a legacy answer.
    """

    @doc "Reads the envelope and parses the payload, the way a legacy map type would."
    @spec load(binary()) :: {:ok, map()} | :error
    def load(bytes) do
      case Format.decode(bytes) do
        {:ok, payload} -> {:ok, Jason.decode!(payload)}
        :error -> :error
      end
    end
  end

  defmodule MapListy do
    @moduledoc "A map-typed reader whose answer is not a map."

    @doc "Answers with a list whatever it was given."
    @spec load(binary()) :: {:ok, list()} | :error
    def load(bytes) do
      case Format.decode(bytes) do
        {:ok, _payload} -> {:ok, ["not", "a", "map"]}
        :error -> :error
      end
    end
  end

  defmodule NotAType do
    @moduledoc "A module that reads nothing: the declaration-time refusal's subject."

    @doc "The only function this module has, and not the one a legacy type needs."
    @spec read(binary()) :: :error
    def read(_bytes), do: :error
  end
end
