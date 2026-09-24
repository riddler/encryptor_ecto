defmodule Encryptor.Ecto.BlindIndex.Value do
  @moduledoc """
  The index value itself: ADR-0003 decision 1, over a declaration.

  `Encryptor.Ecto.BlindIndex.Derivation` answers where the index key comes
  from and `Encryptor.Ecto.BlindIndex.Declaration` answers what the value is
  computed over. This module is the one place the two meet:

      index_value = HMAC-SHA256(index_key, norm(plaintext))

  Or, for a `slow: true` declaration (ADR-0003 decision 6, as amendment C
  fixes it):

      index_value = HMAC-SHA256(index_key, Argon2id(norm(plaintext), index_salt))

  Every surface in `Encryptor.Ecto.BlindIndex` - `put_index/3`, `where_eq/3`,
  `where_eq_candidates/3` and `compute/3` - computes through `compute!/3` and
  nothing else. That is what makes decision 5's promise structural rather than
  a review preference: the write side and the read side cannot disagree about
  normalization or derivation, because neither of them performs either.

  ## The order of operations, and why it is this one

  Three things happen before any plaintext is touched, and the first of them
  is the tenant. A `slow: true` declaration adds a fourth, and it happens
  before the plaintext too.

  1. **The selector is resolved**, which is where a missing tenant raises
     (decision 3a, ADR-0001 decision 5c). It is first because it is the only
     step that does not depend on the value, and because a blind-index
     computation outside tenant scope has to fail the same way whether the
     value is well-formed or not. Decision 5 calls a silently-matching-nothing
     query the single worst failure this feature can have; a scope check that
     could be reached only after a normalizer succeeded would be one that a
     host could stop reaching.
  2. **The slow parameters are read**, for a `slow: true` declaration only,
     which is where amendment C's decision C7 refuses a vault that declares no
     `:slow_hash`. It is here, above the value, for the reason the selector is
     first: what is wrong in that case is the pairing of a declaration and a
     vault configuration, a constant that is wrong in the source, and a
     constant that is wrong in the source has to be wrong whether or not the
     value that arrived happens to normalize.
  3. **The value is normalized** (decision 4), under the declaration's
     normalizer, with the encrypted field's declared table and column reaching
     the failure so it names the schema line.
  4. **The slow hash is taken**, again for a `slow: true` declaration only,
     over the normalized bytes and under a salt derived for this index. The
     *Slow hashing* section below is what that salt is.
  5. **The key is derived** through the vault, and the HMAC is taken over
     whichever of the two the steps above produced.

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

  ## Slow hashing

  `:slow` is the other half of decision 6, and unlike `:bits` it is applied
  *before* the HMAC rather than after it. A `slow: true` declaration hashes
  the normalized value with Argon2id first and takes the HMAC over the 32
  bytes that come back:

      normalized  = norm(plaintext)
      index_salt  = Derivation.derive_salt(vault, derivation, selector)
      slow_input  = Encryptor.Kdf.slow_hash(normalized, index_salt, params)
      index_value = leading bits/8 bytes of HMAC-SHA256(index_key, slow_input)

  Three things about that are decisions rather than implementation, and each
  one is amendment C's:

    * **The parameters are the vault's, never this package's** (C5). They are
      the frozen `:slow_hash` configuration `Encryptor.Ecto.BlindIndex.Derivation.slow_params!/2`
      reads, passed through without being interpreted, and a vault that
      declares none gets a refusal rather than a default - C7, and the reason
      `:slow` shipped inert until the vault had a surface to read them from.
    * **`:slow` does not reach the HKDF `info` string**, exactly as `:bits`
      does not and for the same reason: it is a property of the stored value,
      so flipping it changes the bytes without changing which key the index
      derives. What it *does* change is the salt's `info` - but only by
      existing at all, since a `slow: false` declaration derives no salt.
    * **The salt derivation is lazy** (C5 again). A `slow: false` declaration
      performs exactly one `derive/3` call and decision 1's formula is
      literally unchanged for it; a `slow: true` one performs two, the second
      an HKDF expansion standing next to an Argon2id hash tuned to cost tens
      of mebibytes, which is not the cost anyone will measure.

  Turning `:slow` on over an already-written column invalidates it, in
  decision 7's ordinary sense and with decision 7's two-column dance as the
  migration. Amendment C's C6 calls out the one case a host cannot avoid by
  changing nothing: a column written under a `slow: true` declaration *before*
  this was wired holds plain-HMAC bytes, because the option was accepted and
  inert then.

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
  alias Encryptor.Kdf

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
  encrypts but cannot fingerprint learns it in the same words. A `slow: true`
  declaration also raises `Encryptor.Ecto.BlindIndex.DerivationError` when the
  vault it names declares no `:slow_hash` parameters (amendment C decision
  C7).
  """
  @spec compute!(Declaration.t(), term(), TenantContext.operation()) :: binary()
  def compute!(%Declaration{} = declaration, value, operation),
    do: compute!(declaration, value, operation, Declaration.field_params!(declaration))

  # The same computation over field params the caller supplies, for the one
  # caller that must replace the tenant strategy: the migrator's rewrite pass,
  # folding an index in (ADR-0004's Note of 2026-09-24 on Q1). It installs its
  # per-row resolver in these params exactly as it does in the target type's
  # own (`Encryptor.Ecto.Migrator`'s `target_params/3`), because the field's
  # declared strategy reads a process scope the migrator never sets. Only
  # `:tenant` differs from what `compute!/3` reads; the normalization, the
  # derivation identity and the width are the declaration's either way, so
  # this is the same function rather than a second implementation of it.
  @doc false
  @spec compute!(Declaration.t(), term(), TenantContext.operation(), Derivation.field_params()) ::
          binary()
  def compute!(%Declaration{} = declaration, value, operation, params) do
    derivation = Declaration.derivation!(declaration)
    selector = Derivation.selector!(derivation, params, operation)
    slow_params = slow_params!(declaration, params.vault, derivation)

    normalized = Declaration.normalize!(declaration, value)
    hashed = pre_hash(normalized, params.vault, derivation, selector, slow_params)

    case Derivation.derive(params.vault, derivation, selector) do
      {:ok, index_key} ->
        :hmac
        |> :crypto.mac(:sha256, index_key, hashed)
        |> binary_part(0, byte_width(declaration))

      {:error, error} ->
        raise error
    end
  end

  # `nil` here is "this declaration asked for no slow hashing", and it is the
  # only thing that distinguishes the two arms of `pre_hash/5` below. It is
  # not a parameter set that happens to be absent: enc-ADR-0003 amendment B
  # decision 4 makes a declared set complete by construction, so the vault
  # never hands back a partial one to be filled in here.
  @spec slow_params!(Declaration.t(), module(), Derivation.t()) :: Kdf.params() | nil
  defp slow_params!(%Declaration{slow: false}, _vault, _derivation), do: nil

  defp slow_params!(%Declaration{slow: true}, vault, derivation),
    do: Derivation.slow_params!(vault, derivation)

  # The lazy half of amendment C decision C5: no salt is derived for a
  # declaration that will not hash under one.
  @spec pre_hash(binary(), module(), Derivation.t(), Derivation.selector(), Kdf.params() | nil) ::
          binary()
  defp pre_hash(normalized, _vault, _derivation, _selector, nil), do: normalized

  defp pre_hash(normalized, vault, derivation, selector, slow_params) do
    case Derivation.derive_salt(vault, derivation, selector) do
      {:ok, index_salt} -> Kdf.slow_hash(normalized, index_salt, slow_params)
      {:error, error} -> raise error
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
