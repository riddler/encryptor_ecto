defmodule Encryptor.Ecto.NaiveDateTime do
  @moduledoc """
  An encrypted zoneless timestamp field: `Encryptor.Ecto.Binary` over the
  value's ISO 8601 form (ADR-0001 decision 1).

      defmodule Payments.Encrypted.NaiveDateTime do
        use Encryptor.Ecto.NaiveDateTime, vault: Payments.Vault
      end

      defmodule Payments.Cards.Card do
        use Ecto.Schema

        schema "cards" do
          field :merchant_id, :string
          field :agreed_at, Payments.Encrypted.NaiveDateTime
        end
      end

  Everything below the cast/parse pair is `Encryptor.Ecto.Binary`, called
  rather than copied: the same closed option set, the same declared
  `"table"`/`"column"` context, the same scope resolution, the same `:binary`
  column, the same exception family, and the vault's bytes stored verbatim.
  Read that module for all of it; only the differences are documented here.

  ## The cast/parse pair

  `cast/2` is `Ecto.Type.cast(:naive_datetime, value)` - Ecto's own caster -
  and the plaintext is `NaiveDateTime.to_iso8601/1`, parsed back with
  `NaiveDateTime.from_iso8601/1`.

  The plaintext is exactly `NaiveDateTime.to_iso8601/1`, which writes a `T`:
  `~N[2026-09-12 10:20:30]` is stored as `2026-09-12T10:20:30`. `cloak_ecto`
  1.3.0 writes `to_string/1` for the same value, which is the space-separated
  `2026-09-12 10:20:30`, so the two forms are not the same here. Both of them
  load: `NaiveDateTime.from_iso8601/1` accepts either separator. That leniency
  is what keeps a column readable when ADR-0004's migration hands the migrator
  a legacy plaintext and re-encrypts it verbatim below the schema layer
  (ADR-0002 decision 3).

  A payload that decrypts and then does not parse raises
  `Encryptor.Ecto.SerializationError` with `{:unparsable, :naive_datetime}`:
  the decrypt succeeded, so it is neither an encryption failure nor an
  integrity event, which is the row ADR-0001 decision 6 gives that exception.
  A value that reaches `dump/3` without passing `cast/2` - through
  `insert_all/3`, say - raises `ArgumentError` naming the shape it was given
  and never the value.

  ## Zoneless, and sub-second precision is dropped at the cast

  A `t:NaiveDateTime.t/0` carries no zone, and encrypting it does not give it
  one: the reader gets back the same wall-clock reading the writer stored, and
  what it meant is the host's to know. `Encryptor.Ecto.DateTime` is the type
  for an instant.

  `:naive_datetime` is the primitive this type wraps, and Ecto's caster
  truncates a microsecond field to `{0, 0}` on the way in, exactly as it does
  for a plain `:naive_datetime` column - before any encryption, and visibly in
  the changeset rather than only on the next read.

  ## Everything else

  `nil` is `NULL` and is not encrypted (decision 7). The column is `:binary`,
  not `:naive_datetime` - `type/1` returns `:binary` whatever the plaintext was
  (decision 2). Encrypted columns are not queryable, sortable or uniquely
  indexable (decision 10), so a `BETWEEN` over this column does not mean what
  it would on a plain one.
  """

  alias Encryptor.Ecto.Binary
  alias Encryptor.Ecto.Scalar

  @typedoc """
  The options `use Encryptor.Ecto.NaiveDateTime` accepts.

  Identical to `Encryptor.Ecto.Binary`'s: this type adds no option and removes
  none, and `:json` belongs to `Encryptor.Ecto.Map` alone (decision 3).
  """
  @type opts :: Binary.opts()

  @doc """
  Defines an encrypted zoneless timestamp type on the using module.

  See `Encryptor.Ecto.Binary` for the option set; anything outside it raises
  here, while the host module is compiling.
  """
  @spec __using__(opts()) :: Macro.t()
  defmacro __using__(opts), do: Scalar.host_quote(__MODULE__, :naive_datetime, opts)

  @doc """
  Checks a declaration's option set while the declaring module compiles.

      iex> Encryptor.Ecto.NaiveDateTime.validate_declaration!(
      ...>   Payments.Encrypted.NaiveDateTime,
      ...>   vault: Payments.Vault
      ...> )
      [vault: Payments.Vault]
  """
  @spec validate_declaration!(module(), keyword()) :: keyword()
  def validate_declaration!(module, opts),
    do: Binary.validate_declaration!(module, opts, __MODULE__, [])

  @doc """
  Casts a value on its way into a changeset. Never encrypts.

      iex> Encryptor.Ecto.NaiveDateTime.cast(~N[2026-09-12 10:20:30], %{})
      {:ok, ~N[2026-09-12 10:20:30]}

      iex> Encryptor.Ecto.NaiveDateTime.cast("2026-09-12T10:20:30", %{})
      {:ok, ~N[2026-09-12 10:20:30]}

      iex> Encryptor.Ecto.NaiveDateTime.cast(nil, %{})
      {:ok, nil}

      iex> Encryptor.Ecto.NaiveDateTime.cast("2026-09-12", %{})
      :error
  """
  @spec cast(term(), term()) :: {:ok, Elixir.NaiveDateTime.t() | nil} | :error
  def cast(value, _params), do: Scalar.cast(:naive_datetime, value)
end
