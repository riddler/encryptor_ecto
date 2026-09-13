defmodule Encryptor.Ecto.Time do
  @moduledoc """
  An encrypted time-of-day field: `Encryptor.Ecto.Binary` over the value's
  ISO 8601 form (ADR-0001 decision 1).

      defmodule Payments.Encrypted.Time do
        use Encryptor.Ecto.Time, vault: Payments.Vault
      end

      defmodule Payments.Cards.Card do
        use Ecto.Schema

        schema "cards" do
          field :merchant_id, :string
          field :contact_window_opens_at, Payments.Encrypted.Time
        end
      end

  Everything below the cast/parse pair is `Encryptor.Ecto.Binary`, called
  rather than copied: the same closed option set, the same declared
  `"table"`/`"column"` context, the same tenant resolution, the same `:binary`
  column, the same exception family, and the vault's bytes stored verbatim.
  Read that module for all of it; only the differences are documented here.

  ## The cast/parse pair

  `cast/2` is `Ecto.Type.cast(:time, value)` - Ecto's own caster - and the
  plaintext is `Time.to_iso8601/1`, parsed back with `Time.from_iso8601/1`.

  The textual form is not a choice taken here. `Cloak.Ecto.Time` writes the
  same bytes: `cloak_ecto` 1.3.0 serializes every scalar with `to_string/1`,
  which for a `Time` is byte-identical to `Time.to_iso8601/1`. ADR-0004's
  migration hands the migrator a legacy plaintext and re-encrypts it verbatim
  below the schema layer (ADR-0002 decision 3), so a column arriving from
  `Cloak.Ecto.Time` is readable through this type because the two agree about
  what the bytes say.
  The two datetime types are the exception - see
  `Encryptor.Ecto.NaiveDateTime` - and every kind's exact bytes are pinned in
  `test/encryptor/ecto/scalar_types_test.exs`.

  A payload that decrypts and then does not parse raises
  `Encryptor.Ecto.SerializationError` with `{:unparsable, :time}`: the decrypt
  succeeded, so it is neither an encryption failure nor an integrity event,
  which is the row ADR-0001 decision 6 gives that exception. A value that
  reaches `dump/3` without passing `cast/2` - through `insert_all/3`, say -
  raises `ArgumentError` naming the shape it was given and never the value.

  ## Sub-second precision is dropped at the cast

  `:time` is the primitive this type wraps, and Ecto's caster truncates a
  microsecond field to `{0, 0}` on the way in, exactly as it does for a plain
  `:time` column. The truncation therefore happens before any encryption and is
  visible in the changeset rather than only on the next read. A host that needs
  sub-second precision is not asking for `:time` and should say so with its own
  encoding over `Encryptor.Ecto.String`.

  ## Everything else

  `nil` is `NULL` and is not encrypted (decision 7). The column is `:binary`,
  not `:time` - `type/1` returns `:binary` whatever the plaintext was (decision
  2). Encrypted columns are not queryable, sortable or uniquely indexable
  (decision 10).
  """

  alias Encryptor.Ecto.Binary
  alias Encryptor.Ecto.Scalar

  @typedoc """
  The options `use Encryptor.Ecto.Time` accepts.

  Identical to `Encryptor.Ecto.Binary`'s: this type adds no option and removes
  none, and `:json` belongs to `Encryptor.Ecto.Map` alone (decision 3).
  """
  @type opts :: Binary.opts()

  @doc """
  Defines an encrypted time-of-day type on the using module.

  See `Encryptor.Ecto.Binary` for the option set; anything outside it raises
  here, while the host module is compiling.
  """
  @spec __using__(opts()) :: Macro.t()
  defmacro __using__(opts), do: Scalar.host_quote(__MODULE__, :time, opts)

  @doc """
  Checks a declaration's option set while the declaring module compiles.

      iex> Encryptor.Ecto.Time.validate_declaration!(Payments.Encrypted.Time,
      ...>   vault: Payments.Vault
      ...> )
      [vault: Payments.Vault]
  """
  @spec validate_declaration!(module(), keyword()) :: keyword()
  def validate_declaration!(module, opts),
    do: Binary.validate_declaration!(module, opts, __MODULE__, [])

  @doc """
  Casts a value on its way into a changeset. Never encrypts.

      iex> Encryptor.Ecto.Time.cast(~T[10:20:30], %{})
      {:ok, ~T[10:20:30]}

      iex> Encryptor.Ecto.Time.cast("10:20:30", %{})
      {:ok, ~T[10:20:30]}

      iex> Encryptor.Ecto.Time.cast(nil, %{})
      {:ok, nil}

      iex> Encryptor.Ecto.Time.cast("half past ten", %{})
      :error
  """
  @spec cast(term(), term()) :: {:ok, Elixir.Time.t() | nil} | :error
  def cast(value, _params), do: Scalar.cast(:time, value)
end
