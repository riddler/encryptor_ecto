defmodule Encryptor.Ecto.EncryptError do
  @moduledoc """
  Raised when the vault returns an error encrypting a value (ADR-0001
  decision 6).

  An encrypt failure is an infrastructure failure - a key provider that cannot
  be reached, a wrapping operation that failed - and not a validation error.
  It is deliberately not an `Ecto.Type` `:error`, which would surface as an
  `Ecto.ChangeError` a changeset could catch and then proceed past, writing the
  row without the value it was supposed to protect.
  """

  use Encryptor.Ecto.Error

  @doc false
  @spec headline() :: String.t()
  def headline, do: "the vault failed to encrypt a value for an encrypted field"
end
