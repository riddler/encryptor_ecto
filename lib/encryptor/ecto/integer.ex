defmodule Encryptor.Ecto.Integer do
  @moduledoc """
  An encrypted integer field: `Encryptor.Ecto.Binary` over the value's decimal
  form (ADR-0001 decision 1).

      defmodule Payments.Encrypted.Integer do
        use Encryptor.Ecto.Integer, vault: Payments.Vault
      end

      defmodule Payments.Cards.Card do
        use Ecto.Schema

        schema "cards" do
          field :merchant_id, :string
          field :retry_count, Payments.Encrypted.Integer
        end
      end

  Everything below the cast/parse pair is `Encryptor.Ecto.Binary`, called
  rather than copied: the same closed option set, the same declared
  `"table"`/`"column"` context, the same tenant resolution, the same `:binary`
  column, the same exception family, and the vault's bytes stored verbatim.
  Read that module for all of it; only the differences are documented here.

  ## The cast/parse pair

  `cast/2` is `Ecto.Type.cast(:integer, value)` - Ecto's own caster, so a
  changeset's idea of an integer is the same whether the column is encrypted or
  not, and `"42"` from a form casts exactly as it would on a plain `:integer`
  column. The plaintext that reaches the vault is the value's decimal form, and
  a load parses it back with `Integer.parse/1`, accepting only a payload that
  is a decimal integer and nothing else.

  The textual form is not a choice taken here. `Cloak.Ecto.Integer` writes the
  same bytes: `cloak_ecto` 1.3.0 serializes every scalar with `to_string/1`,
  which for an `Integer` is `Integer.to_string/1`. ADR-0004's migration hands the
  migrator a legacy plaintext and re-encrypts it verbatim below the schema
  layer (ADR-0002 decision 3), so a column arriving from `Cloak.Ecto.Integer` is
  readable through this type because the two agree about what the bytes say.
  The two datetime types are the exception - see
  `Encryptor.Ecto.NaiveDateTime` - and every kind's exact bytes are pinned in
  `test/encryptor/ecto/scalar_types_test.exs`.

  A payload that decrypts and then does not parse raises
  `Encryptor.Ecto.SerializationError` with `{:unparsable, :integer}`: the
  decrypt succeeded, so it is neither an encryption failure nor an integrity
  event, which is the row ADR-0001 decision 6 gives that exception. A value
  that reaches `dump/3` without passing `cast/2` - through `insert_all/3`, say
  - raises `ArgumentError` naming the shape it was given and never the value.

  ## Everything else

  `nil` is `NULL` and is not encrypted; `0` is a value like any other and is
  (decision 7). The column is `:binary`, not `:integer` - `type/1` returns
  `:binary` whatever the plaintext was (decision 2). Encrypted columns are not
  queryable, sortable or uniquely indexable (decision 10): the database sees
  ciphertext, so `where: c.retry_count > 3` and `order_by` do not mean what
  they would on a plain column, and no arithmetic in SQL reaches the value.
  """

  alias Encryptor.Ecto.Binary
  alias Encryptor.Ecto.Scalar

  @typedoc """
  The options `use Encryptor.Ecto.Integer` accepts.

  Identical to `Encryptor.Ecto.Binary`'s: this type adds no option and removes
  none, and `:json` belongs to `Encryptor.Ecto.Map` alone (decision 3).
  """
  @type opts :: Binary.opts()

  @doc """
  Defines an encrypted integer type on the using module.

  See `Encryptor.Ecto.Binary` for the option set; anything outside it raises
  here, while the host module is compiling.
  """
  @spec __using__(opts()) :: Macro.t()
  defmacro __using__(opts), do: Scalar.host_quote(__MODULE__, :integer, opts)

  @doc """
  Checks a declaration's option set while the declaring module compiles.

      iex> Encryptor.Ecto.Integer.validate_declaration!(Payments.Encrypted.Integer,
      ...>   vault: Payments.Vault
      ...> )
      [vault: Payments.Vault]
  """
  @spec validate_declaration!(module(), keyword()) :: keyword()
  def validate_declaration!(module, opts),
    do: Binary.validate_declaration!(module, opts, __MODULE__, [])

  @doc """
  Casts a value on its way into a changeset. Never encrypts.

      iex> Encryptor.Ecto.Integer.cast(42, %{})
      {:ok, 42}

      iex> Encryptor.Ecto.Integer.cast("42", %{})
      {:ok, 42}

      iex> Encryptor.Ecto.Integer.cast(nil, %{})
      {:ok, nil}

      iex> Encryptor.Ecto.Integer.cast("4.2", %{})
      :error
  """
  @spec cast(term(), term()) :: {:ok, integer() | nil} | :error
  def cast(value, _params), do: Scalar.cast(:integer, value)
end
