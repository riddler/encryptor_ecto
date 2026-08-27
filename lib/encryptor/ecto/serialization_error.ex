defmodule Encryptor.Ecto.SerializationError do
  @moduledoc """
  Raised when the serializer behind `Encryptor.Ecto.Map` fails on a value
  (ADR-0001 decision 6).

  The serializer runs on the plaintext side of the type - encoding before the
  dump, decoding after the load - so its failure is neither an encryption
  failure nor an integrity event, and it gets its own exception rather than
  being folded into either.

  `:serializer` names the module that failed (`Jason` by default, per decision
  8) and `:direction` says which half of the round trip it failed in. Neither
  carries the value: a serialization failure is exactly the place where a
  plaintext is closest to hand, and exactly the place ADR-0001 decision 6 calls
  the least excusable leak.
  """

  use Encryptor.Ecto.Error, extra_fields: [serializer: nil, direction: nil]

  @typedoc "Which half of the serializer round trip failed."
  @type direction :: :encode | :decode | nil

  @doc false
  @spec headline() :: String.t()
  def headline, do: "the serializer failed on the value of an encrypted field"

  @doc false
  def extra_detail(%__MODULE__{serializer: serializer, direction: direction}) do
    [{"serializer", inspect(serializer)}, {"direction", inspect(direction)}]
  end
end
