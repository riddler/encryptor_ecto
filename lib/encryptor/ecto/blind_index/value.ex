defmodule Encryptor.Ecto.BlindIndex.Value do
  @moduledoc """
  The index value itself: ADR-0003 decision 1, over a declaration.

  `Encryptor.Ecto.BlindIndex.Derivation` answers where the index key comes
  from and `Encryptor.Ecto.BlindIndex.Declaration` answers what the value is
  computed over. This module is the one place the two meet:

      index_value = HMAC-SHA256(index_key, norm(plaintext))

  Every surface in `Encryptor.Ecto.BlindIndex` - `put_index/3`, `where_eq/3`,
  `where_eq_candidates/3` and `compute/3` - computes through `compute!/3` and
  nothing else. That is what makes decision 5's promise structural rather than
  a review preference: the write side and the read side cannot disagree about
  normalization or derivation, because neither of them performs either.

  ## The order of operations, and why it is this one

  Three things happen before any plaintext is touched, and the first of them
  is the tenant.

  1. **The selector is resolved**, which is where a missing tenant raises
     (decision 3a, ADR-0001 decision 5c). It is first because it is the only
     step that does not depend on the value, and because a blind-index
     computation outside tenant scope has to fail the same way whether the
     value is well-formed or not. Decision 5 calls a silently-matching-nothing
     query the single worst failure this feature can have; a scope check that
     could be reached only after a normalizer succeeded would be one that a
     host could stop reaching.
  2. **The value is normalized** (decision 4), under the declaration's
     normalizer, with the encrypted field's declared table and column reaching
     the failure so it names the schema line.
  3. **The key is derived** through the vault, and the HMAC is taken over the
     normalized bytes.

  ## Width

  The value is the leading `bits / 8` bytes of `HMAC-SHA256`, where `bits` is
  the declaration's - the full 32 at the `bits: 256` default, and 8, 16 or 24
  under `64`, `128` or `192`. That is ADR-0003 decision 6's `:bits`, and three
  things about how it is applied are load-bearing:

    * **The output is truncated, never the key.** The index key stays the full
      32 bytes `Encryptor.Ecto.BlindIndex.Derivation` derives, and `:bits`
      never reaches the derivation - it is not in the HKDF `info` string, and
      a `bits` change therefore does not change which key an index derives.
      Truncating the key instead would weaken the HMAC itself, which is not
      what decision 6 asks for: the record calls `:bits` a *collision* knob,
      and collisions are a property of the stored value's width.
    * **The leading bytes, not the trailing ones.** RFC 2104 section 5 defines
      HMAC truncation as "the leftmost t bits", and NIST SP 800-107 section
      5.3.1 says the same for truncating any approved hash output. Either end
      is equally sound over HMAC-SHA256, so this is a convention rather than a
      security choice - but it is a constant a host's stored bytes depend on
      forever, so it is written down here rather than left to the reader of
      `binary_part/3`.
    * **One place, so the two sides agree.** Truncation happens here, after
      the HMAC and inside the single function every surface computes through,
      so a `put_index/3` write and a `where_eq_candidates/3` read cannot store
      and pin different widths. It is decision 5's promise applied to decision
      6, and it is why `:bits` is read at no call site.

  A `bits` change therefore invalidates the column exactly as decision 7 says
  it does - the stored value changes even though the key does not - and the
  two-column dance is the migration, with the new width declared under its own
  `index_name` or `:version`.

  `:slow` is the other half of decision 6 and is **not** applied here. It is
  accepted and carried by the declaration and does nothing to a computed
  value. Decision 6 puts Argon2id's parameters in "the vault's configuration
  rather than this package's", and the vault exposes no Argon2id surface to
  read them from; inventing one here would be this package choosing a
  cryptographic parameter set, which this repo's conventions call a defect
  even when the choice is a good one. See `ece-6a6`'s notes.

  ## Redaction

  Nothing this module raises carries the plaintext, the normalized value, the
  index value, or the derived key. The index value is on that list for
  ADR-0003's own reason: it is a directly usable search token to anyone who
  reads it out of a log line.

  A vault error is re-raised exactly as the vault phrased it, rather than
  being wrapped. `Encryptor.Ecto.BlindIndex.DerivationError` reports constants
  that are wrong in the source; a vault with no `:derivation_salt` configured
  is neither that nor something this package can see, and putting this
  package's words on it would send a reader to the wrong file.
  """

  alias Encryptor.Ecto.BlindIndex.Declaration
  alias Encryptor.Ecto.BlindIndex.Derivation
  alias Encryptor.Ecto.TenantContext

  @doc """
  The index value for one declaration and one plaintext.

  `operation` is the `Encryptor.Ecto.TenantContext` operation the resolver is
  asked with, and it is the caller's: a **write-side** computation asks with
  `:dump` and a **read-side** computation asks with `:load`, matching what the
  encrypted field itself would be doing at the same moment.
  `Encryptor.Ecto.BlindIndex.Declaration`'s moduledoc records that mapping and
  why it is this package's to make.

  The result is `byte_width/1` bytes wide - the declaration's `:bits`, applied
  to the HMAC output as the moduledoc's *Width* section describes.

  Raises `Encryptor.Ecto.MissingTenantError` when a `scope: :tenant` index is
  computed outside tenant scope, and
  `Encryptor.Ecto.BlindIndex.NormalizationError` when the declared normalizer
  cannot produce a binary. A value that is not a binary is the normalizer's
  refusal rather than a separate one, so a host indexing a field this package
  encrypts but cannot fingerprint learns it in the same words.
  """
  @spec compute!(Declaration.t(), term(), TenantContext.operation()) :: binary()
  def compute!(%Declaration{} = declaration, value, operation) do
    params = Declaration.field_params!(declaration)
    derivation = Declaration.derivation!(declaration)
    selector = Derivation.selector!(derivation, params, operation)

    normalized = Declaration.normalize!(declaration, value)

    case Derivation.derive(params.vault, derivation, selector) do
      {:ok, index_key} ->
        :hmac
        |> :crypto.mac(:sha256, index_key, normalized)
        |> binary_part(0, byte_width(declaration))

      {:error, error} ->
        raise error
    end
  end

  @doc """
  The stored width of one declaration's index value, in bytes.

  Public because it is what a host sizes its index column against, and because
  it is the arithmetic the operator's crypto read checks rather than infers
  from a `div/2` buried in a pipeline.

      iex> Encryptor.Ecto.BlindIndex.Declaration.fetch!(
      ...>   Encryptor.Ecto.TestSchemas.Customer, :email, :email_index)
      ...> |> Encryptor.Ecto.BlindIndex.Value.byte_width()
      32

      iex> Encryptor.Ecto.BlindIndex.Declaration.fetch!(
      ...>   Encryptor.Ecto.TestSchemas.Customer, :email, :email_short_index)
      ...> |> Encryptor.Ecto.BlindIndex.Value.byte_width()
      8
  """
  @spec byte_width(Declaration.t()) :: pos_integer()
  def byte_width(%Declaration{bits: bits}), do: div(bits, 8)
end
