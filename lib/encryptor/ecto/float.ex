defmodule Encryptor.Ecto.Float do
  @moduledoc """
  An encrypted float field: `Encryptor.Ecto.Binary` over the value's textual
  form (ADR-0001 decision 1).

      defmodule Payments.Encrypted.Float do
        use Encryptor.Ecto.Float, vault: Payments.Vault
      end

      defmodule Payments.Cards.Card do
        use Ecto.Schema

        schema "cards" do
          field :merchant_id, :string
          field :fee_rate, Payments.Encrypted.Float
        end
      end

  Everything below the cast/parse pair is `Encryptor.Ecto.Binary`, called
  rather than copied: the same closed option set, the same declared
  `"table"`/`"column"` context, the same scope resolution, the same `:binary`
  column, the same exception family, and the vault's bytes stored verbatim.
  Read that module for all of it; only the differences are documented here.

  ## The cast/parse pair

  `cast/2` is `Ecto.Type.cast(:float, value)` - Ecto's own caster, so an
  integer casts to a float and `"4.2"` from a form casts exactly as it would on
  a plain `:float` column. The plaintext is `Float.to_string/1`, which is the
  shortest form that reads back as the same float, and a load parses it with
  `Float.parse/1`, accepting only a payload that is entirely a number. The
  round trip is therefore exact rather than nearly exact, which is the property
  worth stating for a type whose textual form is usually where precision is
  lost.

  The textual form is not a choice taken here. `Cloak.Ecto.Float` writes the
  same bytes: `cloak_ecto` 1.3.0 serializes every scalar with `to_string/1`,
  which for a `Float` is `Float.to_string/1`. ADR-0004's migration hands the
  migrator a legacy plaintext and re-encrypts it verbatim below the schema
  layer (ADR-0002 decision 3), so a column arriving from `Cloak.Ecto.Float` is
  readable through this type because the two agree about what the bytes say.
  The two datetime types are the exception - see
  `Encryptor.Ecto.NaiveDateTime` - and every kind's exact bytes are pinned in
  `test/encryptor/ecto/scalar_types_test.exs`.

  A payload that decrypts and then does not parse raises
  `Encryptor.Ecto.SerializationError` with `{:unparsable, :float}`: the decrypt
  succeeded, so it is neither an encryption failure nor an integrity event,
  which is the row ADR-0001 decision 6 gives that exception. A value that
  reaches `dump/3` without passing `cast/2` - through `insert_all/3`, say -
  raises `ArgumentError` naming the shape it was given and never the value.
  An integer is one of those shapes: `cast/2` widens it, `dump/3` does not.

  ## Money is not a float, and this type does not make it one

  Said here rather than left to be discovered, because an encrypted amount is
  the field a host reaches for this type to hold. A float cannot represent most
  decimal fractions exactly, and encrypting one changes nothing about that. A
  host storing money stores minor units through `Encryptor.Ecto.Integer`, or
  the decimal's textual form through `Encryptor.Ecto.String`.

  ## Everything else

  `nil` is `NULL` and is not encrypted; `0.0` is a value like any other and is
  (decision 7). The column is `:binary`, not `:float` - `type/1` returns
  `:binary` whatever the plaintext was (decision 2). Encrypted columns are not
  queryable, sortable or uniquely indexable (decision 10): the database sees
  ciphertext, so a range query or an `avg` over this column does not mean what
  it would on a plain one.
  """

  alias Encryptor.Ecto.Binary
  alias Encryptor.Ecto.Scalar

  @typedoc """
  The options `use Encryptor.Ecto.Float` accepts.

  Identical to `Encryptor.Ecto.Binary`'s: this type adds no option and removes
  none, and `:json` belongs to `Encryptor.Ecto.Map` alone (decision 3).
  """
  @type opts :: Binary.opts()

  @doc """
  Defines an encrypted float type on the using module.

  See `Encryptor.Ecto.Binary` for the option set; anything outside it raises
  here, while the host module is compiling.
  """
  @spec __using__(opts()) :: Macro.t()
  defmacro __using__(opts), do: Scalar.host_quote(__MODULE__, :float, opts)

  @doc """
  Checks a declaration's option set while the declaring module compiles.

      iex> Encryptor.Ecto.Float.validate_declaration!(Payments.Encrypted.Float,
      ...>   vault: Payments.Vault
      ...> )
      [vault: Payments.Vault]
  """
  @spec validate_declaration!(module(), keyword()) :: keyword()
  def validate_declaration!(module, opts),
    do: Binary.validate_declaration!(module, opts, __MODULE__, [])

  @doc """
  Casts a value on its way into a changeset. Never encrypts.

      iex> Encryptor.Ecto.Float.cast(4.2, %{})
      {:ok, 4.2}

      iex> Encryptor.Ecto.Float.cast(42, %{})
      {:ok, 42.0}

      iex> Encryptor.Ecto.Float.cast(nil, %{})
      {:ok, nil}

      iex> Encryptor.Ecto.Float.cast("four point two", %{})
      :error
  """
  @spec cast(term(), term()) :: {:ok, float() | nil} | :error
  def cast(value, _params), do: Scalar.cast(:float, value)
end
