defmodule Encryptor.Ecto.Date do
  @moduledoc """
  An encrypted date field: `Encryptor.Ecto.Binary` over the value's ISO 8601
  form (ADR-0001 decision 1).

      defmodule Payments.Encrypted.Date do
        use Encryptor.Ecto.Date, vault: Payments.Vault
      end

      defmodule Payments.Cards.Card do
        use Ecto.Schema

        schema "cards" do
          field :merchant_id, :string
          field :date_of_birth, Payments.Encrypted.Date
        end
      end

  Everything below the cast/parse pair is `Encryptor.Ecto.Binary`, called
  rather than copied: the same closed option set, the same declared
  `"table"`/`"column"` context, the same scope resolution, the same `:binary`
  column, the same exception family, and the vault's bytes stored verbatim.
  Read that module for all of it; only the differences are documented here.

  ## The cast/parse pair

  `cast/2` is `Ecto.Type.cast(:date, value)` - Ecto's own caster, so a
  `t:Date.t/0`, an ISO 8601 string, and the `%{"year" => _, "month" => _,
  "day" => _}` map a form sends all cast exactly as they would on a plain
  `:date` column. The plaintext is `Date.to_iso8601/1` and a load parses it
  with `Date.from_iso8601/1`, accepting a calendar date and nothing else.

  The textual form is not a choice taken here. `Cloak.Ecto.Date` writes the
  same bytes: `cloak_ecto` 1.3.0 serializes every scalar with `to_string/1`,
  which for a `Date` is byte-identical to `Date.to_iso8601/1` on the ISO
  calendar. ADR-0004's migration hands the migrator a legacy plaintext and
  re-encrypts it verbatim below the schema
  layer (ADR-0002 decision 3), so a column arriving from `Cloak.Ecto.Date` is
  readable through this type because the two agree about what the bytes say.
  The two datetime types are the exception - see
  `Encryptor.Ecto.NaiveDateTime` - and every kind's exact bytes are pinned in
  `test/encryptor/ecto/scalar_types_test.exs`.

  A payload that decrypts and then does not parse raises
  `Encryptor.Ecto.SerializationError` with `{:unparsable, :date}`: the decrypt
  succeeded, so it is neither an encryption failure nor an integrity event,
  which is the row ADR-0001 decision 6 gives that exception. A value that
  reaches `dump/3` without passing `cast/2` - through `insert_all/3`, say -
  raises `ArgumentError` naming the shape it was given and never the value.

  ## Everything else

  `nil` is `NULL` and is not encrypted (decision 7). The column is `:binary`,
  not `:date` - `type/1` returns `:binary` whatever the plaintext was (decision
  2), so the database applies no date validation of its own and the migration
  writes `:binary` here as it does for `Binary`. Encrypted columns are not
  queryable, sortable or uniquely indexable (decision 10), and a date is where
  that costs the most: `where: c.date_of_birth < ^cutoff` does not mean what it
  would on a plain column, and an age filter is a host-side pass over decrypted
  rows or a redesign, not an index.
  """

  alias Encryptor.Ecto.Binary
  alias Encryptor.Ecto.Scalar

  @typedoc """
  The options `use Encryptor.Ecto.Date` accepts.

  Identical to `Encryptor.Ecto.Binary`'s: this type adds no option and removes
  none, and `:json` belongs to `Encryptor.Ecto.Map` alone (decision 3).
  """
  @type opts :: Binary.opts()

  @doc """
  Defines an encrypted date type on the using module.

  See `Encryptor.Ecto.Binary` for the option set; anything outside it raises
  here, while the host module is compiling.
  """
  @spec __using__(opts()) :: Macro.t()
  defmacro __using__(opts), do: Scalar.host_quote(__MODULE__, :date, opts)

  @doc """
  Checks a declaration's option set while the declaring module compiles.

      iex> Encryptor.Ecto.Date.validate_declaration!(Payments.Encrypted.Date,
      ...>   vault: Payments.Vault
      ...> )
      [vault: Payments.Vault]
  """
  @spec validate_declaration!(module(), keyword()) :: keyword()
  def validate_declaration!(module, opts),
    do: Binary.validate_declaration!(module, opts, __MODULE__, [])

  @doc """
  Casts a value on its way into a changeset. Never encrypts.

      iex> Encryptor.Ecto.Date.cast(~D[2026-09-12], %{})
      {:ok, ~D[2026-09-12]}

      iex> Encryptor.Ecto.Date.cast("2026-09-12", %{})
      {:ok, ~D[2026-09-12]}

      iex> Encryptor.Ecto.Date.cast(nil, %{})
      {:ok, nil}

      iex> Encryptor.Ecto.Date.cast("12/09/2026", %{})
      :error
  """
  @spec cast(term(), term()) :: {:ok, Elixir.Date.t() | nil} | :error
  def cast(value, _params), do: Scalar.cast(:date, value)
end
