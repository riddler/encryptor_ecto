defmodule Encryptor.Ecto.MissingContextError do
  @moduledoc """
  Raised when the vault reports that required encryption-context keys were not
  supplied (ADR-0001 decision 6, acceptance amendment 2).

  Kept separate from `Encryptor.Ecto.DecryptError` on purpose. The vault's
  `{:missing_required_context_keys, _}` is the one context failure that *is*
  distinguishable in its `:reason`, and what it reports is a host
  misconfiguration - a field pointed at a vault whose profile requires a pair
  this declaration does not supply. That is a deployment defect to fix, not an
  integrity event to investigate, and the two should not page the same person
  with the same words.

  `:missing_keys` carries the key names the vault named. They are names, not
  values.
  """

  use Encryptor.Ecto.Error, extra_fields: [missing_keys: []]

  @doc false
  @spec headline() :: String.t()
  def headline, do: "the vault requires encryption-context keys this field does not supply"

  @doc false
  def extra_detail(%__MODULE__{missing_keys: missing_keys}) do
    [{"missing keys", inspect(missing_keys)}]
  end
end
