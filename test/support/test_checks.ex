defmodule Encryptor.Ecto.TestChecks do
  @moduledoc """
  The host-side `validate:` functions the migration fixtures declare.

  ADR-0004 decision 3b puts this knowledge in the host: a tax identifier is
  nine digits, a card number is sixteen, an address has an `@`. These stand in
  for that, and they are here rather than in `lib/` for the reason the record
  gives for refusing a built-in validator - a generic check would be
  reassurance rather than a control.

  Each is a remote capture a plan can name, because the plan is a compiled
  data structure and an anonymous function cannot survive into one.
  """

  @doc "Sixteen digits and nothing else."
  @spec pan?(term()) :: boolean()
  def pan?(value) when is_binary(value), do: Regex.match?(~r/\A\d{16}\z/, value)
  def pan?(_value), do: false

  @doc "Something shaped like an address."
  @spec email?(term()) :: boolean()
  def email?(value) when is_binary(value), do: String.contains?(value, "@")
  def email?(_value), do: false

  @doc """
  Answers with something that is not a boolean, for the arm where the host's
  check does not keep decision 3b's contract - `{:error, :no_hash_column}` is
  the shape a real one would go wrong in, and it is truthy.
  """
  @spec off_contract?(term()) :: term()
  def off_contract?(_value), do: {:error, :no_hash_column}

  @doc """
  Raises, for the arm where the host's own check is the thing that breaks.

  The message is fixed text: a validator that put the value it rejected into
  its exception would be the leak ADR-0002 decision 11 forbids, and a fixture
  that did it would be a bad example of one.
  """
  @spec raises?(term()) :: boolean()
  def raises?(_value), do: raise(ArgumentError, "the host's validator raised")
end
