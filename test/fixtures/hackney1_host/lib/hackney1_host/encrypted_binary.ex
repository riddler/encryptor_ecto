defmodule Hackney1Host.EncryptedBinary do
  @moduledoc """
  An encrypted field type through the vault above, so that compiling this
  host expands this package's type macro on the hackney 1.x stack.
  """

  use Encryptor.Ecto.Binary, vault: Hackney1Host.Vault
end
