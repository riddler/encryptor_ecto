defmodule Encryptor.Ecto.String do
  @moduledoc """
  An encrypted text field: `Encryptor.Ecto.Binary` with a `t:String.t/0` cast
  arm (ADR-0001 decision 1).

      defmodule Payments.Encrypted.String do
        use Encryptor.Ecto.String, vault: Payments.Vault
      end

      defmodule Payments.Cards.Card do
        use Ecto.Schema

        schema "cards" do
          field :merchant_id, :string
          field :holder_name, Payments.Encrypted.String
        end
      end

  Everything below `cast/2` is `Encryptor.Ecto.Binary`, called rather than
  copied: the same closed option set, the same declared `"table"`/`"column"`
  context, the same tenant resolution, the same `:binary` column, the same
  exception family, and the vault's bytes stored verbatim. Read that module for
  all of it; only the difference is documented here.

  ## The difference is `cast/2`

  `Binary` accepts any binary. This type accepts only a binary that is valid
  UTF-8 - which is what `t:String.t/0` means - and returns the ordinary
  `:error` for one that is not, the way a validation failure should surface
  (decision 6). Choosing `String` over `Binary` for a text column is therefore
  a choice with an effect rather than a naming preference: a changeset that
  hands this field bytes from a file upload or a mis-decoded external payload
  gets an error on the field, instead of a column that decrypts years later
  into something no reader can render.

  `dump/3` and `load/3` are `Binary`'s unchanged, and load deliberately does
  **not** re-check validity. The exception family is fixed by decision 6 and
  adding a class to it is a decision rather than an implementation detail; a
  value that was valid when it was cast is still valid when it comes back, and
  bytes that were not written through this type are the migrator's problem
  (ADR-0002), not a new integrity event invented here.

  The same holds for the migration window: a value that came back through
  `:legacy` is returned as the legacy module produced it, unchecked. That
  module is the host's own working reader for the column, and re-validating
  its answer here would turn a readable legacy row into an exception during
  the one window where the row is supposed to stay readable.

  ## Everything else

  `nil` is `NULL` and `""` is encrypted and round-trips as `""` (decision 7).
  The column is `:binary`, not `:text` - `type/1` returns `:binary` whatever
  the plaintext was (decision 2), so the migration writes `:binary` here just
  as it does for `Binary`. Encrypted columns are not queryable, sortable or
  uniquely indexable (decision 10), and being text changes none of that.
  """

  alias Encryptor.Ecto.Binary

  @typedoc """
  The options `use Encryptor.Ecto.String` accepts.

  Identical to `Encryptor.Ecto.Binary`'s: this type adds no option and removes
  none, and `:json` belongs to `Encryptor.Ecto.Map` alone (decision 3).
  """
  @type opts :: Binary.opts()

  @doc """
  Defines an encrypted text type on the using module.

  See `Encryptor.Ecto.Binary` for the option set; anything outside it raises
  here, while the host module is compiling.
  """
  @spec __using__(opts()) :: Macro.t()
  defmacro __using__(opts) do
    # Named by unquoted module atoms rather than written out, so nothing here
    # injects an alias into the host's namespace on its way past. `binary`
    # carries the delegations that are Binary's outright; `impl` carries the
    # one arm this type replaces.
    impl = __MODULE__
    binary = Binary

    quote do
      @behaviour Ecto.ParameterizedType

      @encryptor_ecto_declared unquote(impl).validate_declaration!(__MODULE__, unquote(opts))

      @doc false
      @impl Ecto.ParameterizedType
      def init(field_opts),
        do: unquote(binary).init(@encryptor_ecto_declared, field_opts)

      @doc false
      @impl Ecto.ParameterizedType
      def type(params), do: unquote(binary).type(params)

      @doc false
      @impl Ecto.ParameterizedType
      def cast(value, params), do: unquote(impl).cast(value, params)

      @doc false
      @impl Ecto.ParameterizedType
      def dump(value, dumper, params), do: unquote(binary).dump(value, dumper, params)

      @doc false
      @impl Ecto.ParameterizedType
      def load(value, loader, params), do: unquote(binary).load(value, loader, params)

      @doc false
      @impl Ecto.ParameterizedType
      def equal?(left, right, params), do: unquote(binary).equal?(left, right, params)

      @doc false
      @impl Ecto.ParameterizedType
      def embed_as(format, params), do: unquote(binary).embed_as(format, params)
    end
  end

  @doc """
  Checks a declaration's option set while the declaring module compiles.

      iex> Encryptor.Ecto.String.validate_declaration!(Payments.Encrypted.String,
      ...>   vault: Payments.Vault
      ...> )
      [vault: Payments.Vault]
  """
  @spec validate_declaration!(module(), keyword()) :: keyword()
  def validate_declaration!(module, opts),
    do: Binary.validate_declaration!(module, opts, __MODULE__, [])

  @doc """
  Casts a value on its way into a changeset. Never encrypts.

  Accepts `nil` and a binary that is valid UTF-8; everything else is a
  validation failure and returns `:error`.

      iex> Encryptor.Ecto.String.cast("Ada Lovelace", %{})
      {:ok, "Ada Lovelace"}

      iex> Encryptor.Ecto.String.cast(nil, %{})
      {:ok, nil}

      iex> Encryptor.Ecto.String.cast(<<0xFF, 0xFE>>, %{})
      :error

      iex> Encryptor.Ecto.String.cast(:not_a_string, %{})
      :error
  """
  @spec cast(term(), term()) :: {:ok, Elixir.String.t() | nil} | :error
  def cast(nil, _params), do: {:ok, nil}

  # `Elixir.String` in full, throughout: this module is itself named `String`,
  # so the bare name is ambiguous to a reader even where the compiler is not
  # confused by it, and the one function that decides what this type accepts is
  # the worst place in the package for a reader to have to guess.
  def cast(value, _params) when is_binary(value) do
    if Elixir.String.valid?(value), do: {:ok, value}, else: :error
  end

  def cast(_value, _params), do: :error
end
