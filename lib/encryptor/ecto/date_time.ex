defmodule Encryptor.Ecto.DateTime do
  @moduledoc """
  An encrypted UTC instant field: `Encryptor.Ecto.Binary` over the value's
  ISO 8601 form (ADR-0001 decision 1).

      defmodule Payments.Encrypted.DateTime do
        use Encryptor.Ecto.DateTime, vault: Payments.Vault
      end

      defmodule Payments.Cards.Card do
        use Ecto.Schema

        schema "cards" do
          field :merchant_id, :string
          field :verified_at, Payments.Encrypted.DateTime
        end
      end

  Everything below the cast/parse pair is `Encryptor.Ecto.Binary`, called
  rather than copied: the same closed option set, the same declared
  `"table"`/`"column"` context, the same scope resolution, the same `:binary`
  column, the same exception family, and the vault's bytes stored verbatim.
  Read that module for all of it; only the differences are documented here.

  ## The cast/parse pair

  `cast/2` is `Ecto.Type.cast(:utc_datetime, value)` - Ecto's own caster - and
  the plaintext is `DateTime.to_iso8601/1`, parsed back with
  `DateTime.from_iso8601/1`.

  The plaintext is exactly `DateTime.to_iso8601/1`, which writes a `T`:
  `~U[2026-09-12 10:20:30Z]` is stored as `2026-09-12T10:20:30Z`.
  `cloak_ecto` 1.3.0 writes `to_string/1` for the same value, which is the
  space-separated `2026-09-12 10:20:30Z`, so the two forms are not the same
  here. Both of them load: `DateTime.from_iso8601/1` accepts either
  separator. That leniency is what keeps a column readable when ADR-0004's
  migration hands the migrator a legacy plaintext and re-encrypts it verbatim
  below the schema layer (ADR-0002 decision 3).

  A payload that decrypts and then does not parse raises
  `Encryptor.Ecto.SerializationError` with `{:unparsable, :utc_datetime}`: the
  decrypt succeeded, so it is neither an encryption failure nor an integrity
  event, which is the row ADR-0001 decision 6 gives that exception. A value
  that reaches `dump/3` without passing `cast/2` - through `insert_all/3`, say
  - raises `ArgumentError` naming the shape it was given and never the value.

  ## UTC only, and sub-second precision is dropped at the cast

  `:utc_datetime` is the primitive this type wraps, so a cast value is always
  in `Etc/UTC` and `dump/3` refuses a `t:DateTime.t/0` in any other zone rather
  than storing it. The refusal is the point: the ISO 8601 form of a zoned
  datetime carries its offset, `DateTime.from_iso8601/1` resolves that to the
  equivalent UTC instant, and accepting one would silently drop the zone on
  every read instead of on the one write a host can still correct.

  Ecto's caster likewise truncates a microsecond field to `{0, 0}` on the way
  in, exactly as it does for a plain `:utc_datetime` column - before any
  encryption, and visibly in the changeset rather than only on the next read.

  The read is lenient where the write is strict, and that asymmetry is
  deliberate rather than an oversight. `DateTime.from_iso8601/1` accepts a
  plaintext carrying any offset, resolves it to the equivalent UTC instant,
  and discards the offset - the very thing the `dump/3` refusal above exists
  to prevent on the write side. It is unreachable through this type's own
  writes, which always store `Z`; it is reachable through a plaintext that
  arrived from somewhere else, and there a readable instant beats a refusal.

  ## Everything else

  `nil` is `NULL` and is not encrypted (decision 7). The column is `:binary`,
  not `:utc_datetime` - `type/1` returns `:binary` whatever the plaintext was
  (decision 2). Encrypted columns are not queryable, sortable or uniquely
  indexable (decision 10), so an "expires before" query or an index-backed
  ordering over this column is not available and is not quietly approximated
  here.
  """

  alias Encryptor.Ecto.Binary
  alias Encryptor.Ecto.Scalar

  @typedoc """
  The options `use Encryptor.Ecto.DateTime` accepts.

  Identical to `Encryptor.Ecto.Binary`'s: this type adds no option and removes
  none, and `:json` belongs to `Encryptor.Ecto.Map` alone (decision 3).
  """
  @type opts :: Binary.opts()

  @doc """
  Defines an encrypted UTC instant type on the using module.

  See `Encryptor.Ecto.Binary` for the option set; anything outside it raises
  here, while the host module is compiling.
  """
  @spec __using__(opts()) :: Macro.t()
  defmacro __using__(opts), do: Scalar.host_quote(__MODULE__, :utc_datetime, opts)

  @doc """
  Checks a declaration's option set while the declaring module compiles.

      iex> Encryptor.Ecto.DateTime.validate_declaration!(Payments.Encrypted.DateTime,
      ...>   vault: Payments.Vault
      ...> )
      [vault: Payments.Vault]
  """
  @spec validate_declaration!(module(), keyword()) :: keyword()
  def validate_declaration!(module, opts),
    do: Binary.validate_declaration!(module, opts, __MODULE__, [])

  @doc """
  Casts a value on its way into a changeset. Never encrypts.

      iex> Encryptor.Ecto.DateTime.cast(~U[2026-09-12 10:20:30Z], %{})
      {:ok, ~U[2026-09-12 10:20:30Z]}

      iex> Encryptor.Ecto.DateTime.cast("2026-09-12T10:20:30Z", %{})
      {:ok, ~U[2026-09-12 10:20:30Z]}

      iex> Encryptor.Ecto.DateTime.cast(nil, %{})
      {:ok, nil}

      iex> Encryptor.Ecto.DateTime.cast("yesterday", %{})
      :error
  """
  @spec cast(term(), term()) :: {:ok, Elixir.DateTime.t() | nil} | :error
  def cast(value, _params), do: Scalar.cast(:utc_datetime, value)
end
