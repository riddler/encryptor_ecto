defmodule Encryptor.Ecto.BlindIndex.Normalizer do
  @moduledoc """
  The normalizers a blind index declares, and the guarantee that applying one
  is total (ADR-0003 decision 4).

  An index answers equality over `norm(plaintext)`, never over plaintext. This
  module is `norm`: it is handed a binary and a declared normalizer and
  returns the bytes the HMAC is computed over. It computes no index values, it
  reads no schema, and it holds no key material.

  ## The set

  | Normalizer | Does |
  |---|---|
  | `:none` | Byte-exact. The default, because the default should be the one that loses nothing |
  | `:trim` | `String.trim/1` |
  | `:downcase` | `String.trim/1` then `String.downcase/1` |
  | `:email` | Exactly `:downcase`. The local part is case-sensitive per RFC 5321 and no host wants that |
  | `:digits` | Keeps the bytes `?0..?9` and drops everything else |
  | `{module, function}` | A host-supplied `(binary() -> binary())` |

  ## Normalization is lossy and directional, and changing it is a reindex

  Both consequences are stated at the option rather than left to a rotation
  appendix, because the moment a host chooses a normalizer is the only moment
  the choice is free.

  **Lossy and directional.** A `:downcase` index finds `"Bob@Example.COM "`
  when asked for `"bob@example.com"`. A host that reads an index hit as proof
  of byte equality is wrong, and the wrongness is invisible until two values
  that normalize together are treated as one. It matters most where ADR-0003
  decision 9 allows a unique constraint over the index column: the constraint
  is then uniqueness of `norm(plaintext)` within the key's scope, so a
  normalizer that merges two real values merges two real rows.

  **Changing it invalidates the column.** Every stored value was computed
  under the old rule, so a normalizer change is a reindex - decision 7's
  two-column sequence, handled exactly like a key rotation. The normalizer is
  deliberately *not* mixed into the HKDF `info`
  (`Encryptor.Ecto.BlindIndex.Derivation`): mixing it in would turn a
  normalizer change into a silent no-match, where every lookup quietly returns
  nothing, instead of a reindex the host has to plan. The reindex is the
  honest path.

  ## `:digits` and international phone numbers

  ADR-0003 open question Q5, carried here and still open. Stripping to digits
  is right for a single-country host and merges `"+1 555 0100"` with
  `"5550100"`, which under a unique constraint can merge two real people's
  rows. The record ships the normalizer and flags it; nothing here resolves
  it. A host with international numbers should normalize to E.164 with its own
  `{module, function}` normalizer rather than reach for `:digits`.

  ## Totality

  ADR-0003 requires normalizers to be pure and total, and to raise on no
  binary. The built-ins meet that on every binary including one that is not
  valid UTF-8: `:digits` iterates bytes, and `String.trim/1` and
  `String.downcase/1` pass bytes they cannot interpret through unchanged
  rather than raising. There is therefore no arm on which a built-in
  normalizer can fail, which is why every condition
  `Encryptor.Ecto.BlindIndex.NormalizationError` reports comes from a host
  normalizer or from a non-binary argument.

  A host normalizer gets no such guarantee, so it is called inside a rescue.
  Raising, throwing, exiting, not being exported, and returning anything that
  is not a binary all become the same `NormalizationError`, which names the
  table, the column, the index and the normalizer - and no value.
  """

  alias Encryptor.Ecto.BlindIndex.NormalizationError

  @builtin [:none, :trim, :downcase, :email, :digits]

  @typedoc "A declared normalizer: one of the built-in atoms, or a host function."
  @type t :: :none | :trim | :downcase | :email | :digits | {module(), atom()}

  @typedoc """
  What a failure is allowed to name: the encrypted field's declared table and
  column, and the index being computed. Never a value.
  """
  @type context :: [
          table: String.t() | nil,
          column: String.t() | nil,
          index_name: String.t() | nil
        ]

  @doc """
  The built-in normalizer names, in the order ADR-0003 decision 4 tables them.

      iex> Encryptor.Ecto.BlindIndex.Normalizer.builtin()
      [:none, :trim, :downcase, :email, :digits]
  """
  @spec builtin() :: [atom()]
  def builtin, do: @builtin

  @doc """
  Whether a term is a normalizer this package will accept at a declaration.

  A `{module, function}` pair is accepted on its shape alone. Whether the
  function exists cannot be answered where the declaration is written - the
  host module naming it may not be compiled yet, and a check that forced it to
  be would make declaration order significant.

      iex> alias Encryptor.Ecto.BlindIndex.Normalizer
      iex> {Normalizer.valid?(:email), Normalizer.valid?({MyApp.Phone, :e164})}
      {true, true}

      iex> alias Encryptor.Ecto.BlindIndex.Normalizer
      iex> {Normalizer.valid?(:uppercase), Normalizer.valid?({MyApp.Phone, "e164"})}
      {false, false}
  """
  @spec valid?(term()) :: boolean()
  def valid?(normalizer) when normalizer in @builtin, do: true

  def valid?({module, function}) when is_atom(module) and is_atom(function),
    do: named?(module) and named?(function)

  def valid?(_normalizer), do: false

  @doc """
  Applies a declared normalizer to one value.

      iex> Encryptor.Ecto.BlindIndex.Normalizer.normalize!(:email, " Bob@Example.COM ")
      "bob@example.com"

      iex> Encryptor.Ecto.BlindIndex.Normalizer.normalize!(:digits, "+1 (555) 0100")
      "15550100"

      iex> Encryptor.Ecto.BlindIndex.Normalizer.normalize!(:none, " Bob@Example.COM ")
      " Bob@Example.COM "

  `context` is what a failure is allowed to name, and the caller supplies it
  because this module has no schema to read it from.
  `Encryptor.Ecto.BlindIndex.Declaration.normalize!/2` is the arm that fills it
  in from the declaration.

      iex> Encryptor.Ecto.BlindIndex.Normalizer.normalize!(
      ...>   {String, :to_atom}, "bob", table: "signups", column: "email",
      ...>   index_name: "email_index")
      ** (Encryptor.Ecto.BlindIndex.NormalizationError) a blind index value could not be normalized (table: "signups", column: "email", context keys: [], tenant: nil, reason: {:returned, :not_a_binary}, index name: "email_index", normalizer: {String, :to_atom})
  """
  @spec normalize!(t(), binary(), context()) :: binary()
  def normalize!(normalizer, value, context \\ [])

  def normalize!(normalizer, value, context) when is_binary(value) do
    case normalizer do
      :none -> value
      :trim -> String.trim(value)
      :downcase -> value |> String.trim() |> String.downcase()
      :email -> value |> String.trim() |> String.downcase()
      :digits -> digits(value)
      {module, function} -> host(normalizer, module, function, value, context)
      other -> refuse!(other, context, {:invalid, :normalize, :unknown_normalizer})
    end
  end

  def normalize!(normalizer, _value, context),
    do: refuse!(normalizer, context, {:invalid, :value, :not_a_binary})

  # Byte-wise on purpose. A codepoint-wise filter would have to decode, and
  # decoding is the one thing a total function over arbitrary binaries cannot
  # promise; the ASCII digits are single bytes in UTF-8 and in every encoding
  # a `:binary` column is likely to hold, so the byte filter is also the
  # correct one rather than merely the safe one.
  @spec digits(binary()) :: binary()
  defp digits(value), do: for(<<byte <- value>>, byte in ?0..?9, into: "", do: <<byte>>)

  # Every way a host function can fail to be `(binary() -> binary())` collapses
  # here into one exception. Notably including the exception's *message* would
  # be the leak: a normalizer that raises on the value it was handed usually
  # names that value, and the value is a plaintext.
  @spec host(t(), module(), atom(), binary(), context()) :: binary()
  defp host(normalizer, module, function, value, context) do
    case call(module, function, value) do
      {:ok, normalized} when is_binary(normalized) -> normalized
      {:ok, _not_a_binary} -> refuse!(normalizer, context, {:returned, :not_a_binary})
      {:error, reason} -> refuse!(normalizer, context, reason)
    end
  end

  @spec call(module(), atom(), binary()) :: {:ok, term()} | {:error, term()}
  defp call(module, function, value) do
    {:ok, apply(module, function, [value])}
  rescue
    exception -> {:error, {:raised, exception.__struct__}}
  catch
    :throw, _thrown -> {:error, {:threw, :a_value}}
    :exit, _reason -> {:error, {:exited, :for_a_reason}}
  end

  # `nil`, `true` and `false` are atoms, and a `{nil, nil}` normalizer would
  # otherwise pass a shape check and fail at the first write.
  @spec named?(atom()) :: boolean()
  defp named?(atom), do: atom not in [nil, true, false]

  @spec refuse!(term(), context(), term()) :: no_return()
  defp refuse!(normalizer, context, reason) do
    raise NormalizationError,
      table: Keyword.get(context, :table),
      column: Keyword.get(context, :column),
      context_keys: [],
      tenant: nil,
      reason: reason,
      index_name: Keyword.get(context, :index_name),
      normalizer: normalizer
  end
end
