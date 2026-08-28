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

  The value is the full 32 bytes of `HMAC-SHA256`. A declaration carrying
  `bits: 64` is carried, not applied: what `:bits` and `:slow` *do* to a
  computed value is ADR-0003 decision 6's option half, and it is not
  implemented here. Both are read only where the record already says they are
  read - `where_eq/3` refuses a truncated index by name - so nothing in this
  module has to change when the option half lands, and a declaration written
  today with `bits: 64` stores a full-width value in the meantime.

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
      {:ok, index_key} -> :crypto.mac(:hmac, :sha256, index_key, normalized)
      {:error, error} -> raise error
    end
  end
end
