defmodule Encryptor.Ecto.BlindIndex.NormalizationError do
  @moduledoc """
  Raised when a field's declared normalizer could not produce a normalized
  value (ADR-0003's exception table, the "a host normalizer raises or returns
  a non-binary" row).

  The built-in normalizers never reach this exception. They are total on every
  binary by construction - `Encryptor.Ecto.BlindIndex.Normalizer` says how -
  so every condition reported here is either a `{module, function}` normalizer
  the host supplied misbehaving, or a value that is not a binary arriving
  where one was required.

  ## What it names, and what it cannot name

  The common fields carry the *encrypted field's* declared table and column,
  and `:index_name` names which of a column's indexes was being computed. That
  is deliberately the whole identification: ADR-0003 decision 4 says the
  exception names the table and column and no value, and the value in hand at
  the moment a normalizer fails is a plaintext.

  So the plaintext is absent, and so is anything derived from it. In
  particular a rescued exception's *message* is not carried - a host
  normalizer that raises `ArgumentError` on the value it was handed usually
  puts that value in the message, which would smuggle the plaintext into this
  exception through the one field that looks safe to copy. `:reason` carries
  the rescued exception's module and nothing else.

  `:normalizer` is the declaration's own `:normalize` option: an atom, or the
  `{module, function}` pair the host wrote. Both are names from the schema
  line, which is what makes the failure findable.
  """

  use Encryptor.Ecto.Error, extra_fields: [index_name: nil, normalizer: nil]

  @doc false
  @spec headline() :: String.t()
  def headline, do: "a blind index value could not be normalized"

  @doc false
  def extra_detail(%__MODULE__{index_name: index_name, normalizer: normalizer}) do
    [{"index name", inspect(index_name)}, {"normalizer", inspect(normalizer)}]
  end
end
