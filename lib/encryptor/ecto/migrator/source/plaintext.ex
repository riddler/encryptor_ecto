defmodule Encryptor.Ecto.Migrator.Source.Plaintext do
  @moduledoc """
  The source for a column that was never encrypted.

  ADR-0002 decision 8's other adoption path. A host adopting encryption on a
  plaintext column is **not** doing a data-only migration: plaintext lives in
  a `:string`/`:text` column and ciphertext must live in a `:binary` one, so
  the move is an expand/backfill/contract dance across two columns and two
  deploys. The migrator does the backfill leg - the plan's `into:` names the
  new ciphertext column - and the DDL and the cutover are the host's own Ecto
  migrations, in a documented runbook. This package issues no DDL (ADR-0002
  decision 9).

  As a source it is the identity: the column already holds the value, so
  there is nothing to decrypt and nothing that can fail to decrypt. A plan
  naming it therefore has no `:undecryptable` class to speak of, and the
  probe's usual signal - a failed decrypt - carries no information about
  these rows.

  Worth stating plainly, because the runbook depends on it: while the
  backfill runs, the plaintext column still holds plaintext. The security
  improvement lands at the contract step, when that column is dropped, not
  when the backfill finishes.

      field :notes, from: Encryptor.Ecto.Migrator.Source.Plaintext,
                    to: Signup.Encrypted.String,
                    into: :notes_encrypted
  """

  alias Encryptor.Ecto.Migrator.Source

  @behaviour Source

  @doc """
  Returns the column's value unchanged.

  A `nil` passes through, so a plan naming this source classifies its empty
  rows the same way every other plan does. Anything that is neither a binary
  nor `nil` is `{:error, :not_plaintext}`: the migrator reads raw column
  values, and a term of another shape means the plan named a column this
  source cannot be responsible for. The offending value is not carried into
  the reason - it is the plaintext.
  """
  @impl Source
  @spec load(binary() | nil, Source.params()) :: {:ok, binary() | nil} | {:error, term()}
  def load(nil, _params), do: {:ok, nil}
  def load(value, _params) when is_binary(value), do: {:ok, value}
  def load(_value, _params), do: {:error, :not_plaintext}
end
