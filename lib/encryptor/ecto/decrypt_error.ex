defmodule Encryptor.Ecto.DecryptError do
  @moduledoc """
  Raised when stored bytes fail to decrypt (ADR-0001 decision 6), whether
  because the vault rejected them or because they are not a well-formed
  message at all.

  A decrypt failure is an *integrity event*. Because the encryption context is
  bound into the message as additional authenticated data, a ciphertext lifted
  out of one row and dropped into another fails authentication rather than
  decrypting into the wrong place - so this exception is what that
  anti-substitution property looks like when it fires.

  ## `:engine` is not a contract

  Acceptance amendment 2: every message-dependent decrypt failure arrives from
  the vault as `:decrypt_failed`, so an AAD mismatch is *not* distinguishable
  in `:reason` and this exception cannot branch on it. The operator-facing
  detail - `{:encryption_context_mismatch, key}` and its neighbours - is
  carried in `:engine`, which is not a versioned contract.

  **Never match on `:engine` for control flow.** It exists to be read by a
  person during an investigation, and its shape may change with any release of
  the vault. Like every other field here it is rendered through
  `Encryptor.Ecto.Error.redact/1`, so a binary inside it reaches the message as
  a byte count.
  """

  use Encryptor.Ecto.Error, extra_fields: [engine: nil]

  @doc false
  @spec headline() :: String.t()
  def headline, do: "the vault failed to decrypt the stored bytes of an encrypted field"

  @doc false
  def extra_detail(%__MODULE__{engine: engine}) do
    [{"engine", Error.redact(engine)}]
  end
end
