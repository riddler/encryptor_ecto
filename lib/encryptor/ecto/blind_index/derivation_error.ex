defmodule Encryptor.Ecto.BlindIndex.DerivationError do
  @moduledoc """
  Raised when a blind index's key cannot be derived (ADR-0003's exception
  table, the "key derivation fails upstream" row).

  Every condition this exception reports is a *constant that is wrong in the
  source* rather than an event that happens to a correct program: a
  declaration with no table, an `index_name` carrying the info string's own
  separator, a version that is not a positive integer, key material that is
  too short to expand from. `Encryptor.Kdf` takes the same position for the
  same reason and raises `ArgumentError` at its own boundary; this package
  checks the arguments before that boundary so the failure names the
  declaration the host wrote rather than a length constraint one call further
  down.

  ## `:index_name` and `:version`

  The common fields carry the *encrypted field's* declared table and column -
  the same values ADR-0001 decision 4 freezes and every other member of the
  family reports. `:index_name` and `:version` are the two remaining
  components of the HKDF `info` string (ADR-0003 decision 2 as amended by the
  2026-08-27 D1 ruling), and they are here because an error naming only the
  column cannot distinguish two indexes declared over one column.

  All four are schema-level names and integers. None of them is key material,
  and neither is `:reason`, which is always a tuple of atoms describing the
  constraint that was violated. `Encryptor.Ecto.Error`'s prohibition applies
  here unchanged and with one addition ADR-0003 makes explicit: an index
  *value* is a directly usable search token, so it never reaches a message,
  a log line, or `Inspect` output either.
  """

  use Encryptor.Ecto.Error, extra_fields: [index_name: nil, version: nil]

  @doc false
  @spec headline() :: String.t()
  def headline, do: "a blind index key could not be derived"

  @doc false
  def extra_detail(%__MODULE__{index_name: index_name, version: version}) do
    [{"index name", inspect(index_name)}, {"index version", inspect(version)}]
  end
end
