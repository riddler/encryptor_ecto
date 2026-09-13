defmodule Encryptor.Ecto.Scalar do
  @moduledoc false

  # The machinery behind the six scalar types ADR-0001 decision 1 leaves out of
  # the founding set: `Integer`, `Float`, `Date`, `Time`, `NaiveDateTime` and
  # `DateTime`. The record calls them "mechanical wrappers over `Binary` with a
  # cast/parse pair", and this is the one copy of the mechanism they share.
  #
  # It is deliberately not public. A host never names this module: it declares
  # `use Encryptor.Ecto.Date` and the generated callbacks come through here.
  # The six public modules carry the documentation, the doctests and the cast
  # arm, exactly as `Encryptor.Ecto.String` and `Encryptor.Ecto.Map` do; what
  # they do not carry is six copies of the same delegation quote.
  #
  # The plaintext a scalar encrypts is its *textual* form - a decimal integer,
  # a shortest-round-trip float, and `to_iso8601/1` for the four date and time
  # kinds, which puts a `T` between a date and a time. `cloak_ecto` 1.3.0
  # writes `to_string/1` instead (`lib/cloak_ecto/type.ex`'s default
  # `before_encrypt/1`, re-stated in each of its date and time types): the
  # same bytes for an integer, a float, a `Date` and a `Time`, and the
  # *space*-separated form for a `NaiveDateTime` and a `DateTime`. Both forms
  # load, because `NaiveDateTime.from_iso8601/1` and `DateTime.from_iso8601/1`
  # accept either separator - and that leniency, rather than an agreement
  # about the written form, is what keeps a column readable when ADR-0004's
  # migration story hands the migrator legacy plaintext and re-encrypts it
  # verbatim below the schema layer (ADR-0002 decision 3). The exact bytes of
  # all six are pinned in `test/encryptor/ecto/scalar_types_test.exs`.

  alias Encryptor.Ecto.Binary
  alias Encryptor.Ecto.SerializationError

  @typedoc false
  @type kind :: :integer | :float | :date | :time | :naive_datetime | :utc_datetime

  @doc false
  # The callbacks each public scalar type injects into the host's module. Named
  # by unquoted module atoms rather than written out, so nothing here injects
  # an alias into the host's namespace on its way past - and `impl` rather than
  # `__MODULE__`, so every message a host sees names the macro it wrote.
  @spec host_quote(module(), kind(), Macro.t()) :: Macro.t()
  def host_quote(impl, kind, opts) do
    scalar = __MODULE__
    binary = Binary

    quote do
      @behaviour Ecto.ParameterizedType

      @encryptor_ecto_declared unquote(impl).validate_declaration!(__MODULE__, unquote(opts))

      # The marker every encrypted field carries, for the reason
      # `Encryptor.Ecto.Declarations` gives at its own use of it. A scalar
      # field freezes a declared context and rides it as AAD exactly as a
      # binary one does, so it is as substitutable with a colliding
      # declaration as a binary field is.
      @doc false
      def __encryptor_ecto__(:impl), do: unquote(impl)

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
      def dump(value, dumper, params),
        do: unquote(scalar).dump(unquote(impl), unquote(kind), value, dumper, params)

      @doc false
      @impl Ecto.ParameterizedType
      def load(value, loader, params),
        do: unquote(scalar).load(unquote(impl), unquote(kind), value, loader, params)

      @doc false
      @impl Ecto.ParameterizedType
      def equal?(left, right, params), do: unquote(binary).equal?(left, right, params)

      @doc false
      @impl Ecto.ParameterizedType
      def embed_as(format, params), do: unquote(binary).embed_as(format, params)
    end
  end

  @doc false
  # `Ecto.Type.cast/2` over the primitive the type wraps, and nothing else.
  # Borrowing Ecto's own caster is what keeps a changeset's idea of "a date"
  # the same whether the column is encrypted or not, and it is the half of the
  # cast/parse pair that has no encryption in it at all.
  @spec cast(kind(), term()) :: {:ok, term()} | :error
  def cast(kind, value), do: Ecto.Type.cast(primitive(kind), value)

  @doc false
  @spec dump(module(), kind(), term(), term(), Binary.params()) :: {:ok, binary() | nil}
  def dump(_impl, _kind, nil, _dumper, _params), do: {:ok, nil}

  def dump(impl, kind, value, dumper, params) do
    case to_plaintext(kind, value) do
      {:ok, plaintext} -> Binary.dump(plaintext, dumper, params)
      :error -> refuse!(impl, kind, params, value)
    end
  end

  @doc false
  @spec load(module(), kind(), term(), term(), Binary.params()) :: {:ok, term()}
  def load(_impl, _kind, nil, _loader, _params), do: {:ok, nil}

  def load(impl, kind, value, _loader, params) when is_binary(value) do
    # `load_arm/2` rather than `load/3` for the reason `Encryptor.Ecto.Map`
    # asks the same question: the parse arm belongs to the vault's plaintext
    # alone. A value that came back through the migration window's `:legacy`
    # module has already been parsed by that module and is returned as it
    # produced it, unchecked - the same rule `Encryptor.Ecto.String` states for
    # validity. Re-parsing it would raise on the one reader that is supposed to
    # keep the row readable during the window.
    case Binary.load_arm(value, params) do
      {:primary, plaintext} -> {:ok, parse!(impl, kind, plaintext, params)}
      {:legacy, loaded} -> {:ok, loaded}
    end
  end

  # Anything else is not a stored value at all, and `Binary.load/3`'s own
  # catch-all refuses it by shape without rendering it - the same message, from
  # the module that owns the rule.
  def load(_impl, _kind, value, loader, params), do: Binary.load(value, loader, params)

  # -- the cast/parse pair ---------------------------------------------------

  # `Elixir.`-qualified throughout: four of the six modules this serves are
  # themselves named `Date`, `Time`, `DateTime` and `NaiveDateTime`, and the
  # functions that decide what the stored bytes say are the worst place in the
  # package for a reader to have to work out which module a bare name means.
  @spec primitive(kind()) :: atom()
  defp primitive(:integer), do: :integer
  defp primitive(:float), do: :float
  defp primitive(:date), do: :date
  defp primitive(:time), do: :time
  defp primitive(:naive_datetime), do: :naive_datetime
  defp primitive(:utc_datetime), do: :utc_datetime

  @spec to_plaintext(kind(), term()) :: {:ok, binary()} | :error
  defp to_plaintext(:integer, value) when is_integer(value),
    do: {:ok, Elixir.Integer.to_string(value)}

  defp to_plaintext(:float, value) when is_float(value),
    do: {:ok, Elixir.Float.to_string(value)}

  defp to_plaintext(:date, %Elixir.Date{} = value),
    do: {:ok, Elixir.Date.to_iso8601(value)}

  defp to_plaintext(:time, %Elixir.Time{} = value),
    do: {:ok, Elixir.Time.to_iso8601(value)}

  defp to_plaintext(:naive_datetime, %Elixir.NaiveDateTime{} = value),
    do: {:ok, Elixir.NaiveDateTime.to_iso8601(value)}

  # UTC only, matching the `:utc_datetime` primitive the cast arm uses: a
  # zoned datetime's ISO 8601 form carries its offset and comes back as the
  # equivalent UTC instant, so accepting one would silently drop the zone on
  # every read rather than on the write a host can still fix.
  defp to_plaintext(:utc_datetime, %Elixir.DateTime{time_zone: "Etc/UTC"} = value),
    do: {:ok, Elixir.DateTime.to_iso8601(value)}

  defp to_plaintext(_kind, _value), do: :error

  @spec from_plaintext(kind(), binary()) :: {:ok, term()} | :error
  defp from_plaintext(:integer, plaintext) do
    case Elixir.Integer.parse(plaintext) do
      {value, ""} -> {:ok, value}
      _other -> :error
    end
  end

  defp from_plaintext(:float, plaintext) do
    case Elixir.Float.parse(plaintext) do
      {value, ""} -> {:ok, value}
      _other -> :error
    end
  end

  defp from_plaintext(:date, plaintext), do: unwrap(Elixir.Date.from_iso8601(plaintext))
  defp from_plaintext(:time, plaintext), do: unwrap(Elixir.Time.from_iso8601(plaintext))

  defp from_plaintext(:naive_datetime, plaintext),
    do: unwrap(Elixir.NaiveDateTime.from_iso8601(plaintext))

  defp from_plaintext(:utc_datetime, plaintext) do
    case Elixir.DateTime.from_iso8601(plaintext) do
      {:ok, value, _offset} -> {:ok, value}
      {:error, _reason} -> :error
    end
  end

  @spec unwrap({:ok, term()} | {:error, term()}) :: {:ok, term()} | :error
  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap({:error, _reason}), do: :error

  @spec parse!(module(), kind(), term(), Binary.params()) :: term()
  defp parse!(impl, kind, plaintext, params) when is_binary(plaintext) do
    case from_plaintext(kind, plaintext) do
      {:ok, value} -> value
      :error -> raise SerializationError, detail(impl, kind, params, {:unparsable, kind})
    end
  end

  # The vault returns a binary, so this arm is unreachable through the vault
  # and reachable through a `:legacy`-free declaration only if some other
  # reader is ever wired in below. It refuses rather than matching, for the
  # same reason `Encryptor.Ecto.Map` refuses a payload that parsed into a list:
  # a value the type cannot return is not a value to return.
  defp parse!(impl, kind, _plaintext, params),
    do: raise(SerializationError, detail(impl, kind, params, {:unparsable, kind}))

  # -- failures --------------------------------------------------------------

  # The parse runs on the plaintext side of the vault call, after a decrypt
  # that succeeded, so its failure is neither an encryption failure nor an
  # integrity event - which is exactly the reason ADR-0001 decision 6 gives
  # `Encryptor.Ecto.SerializationError` its own row. `:serializer` names the
  # type module whose parse arm refused, and the reason carries the kind as an
  # atom rather than the payload: `Encryptor.Ecto.Error.redact/1` renders any
  # binary as its byte count, and the payload here is a plaintext.
  @spec detail(module(), kind(), Binary.params(), term()) :: keyword()
  defp detail(impl, _kind, params, reason) do
    [
      table: params.table,
      column: params.column,
      context_keys: Binary.context_keys(params),
      tenant: nil,
      reason: reason,
      serializer: impl,
      direction: :decode
    ]
  end

  # The value is never rendered, only its shape - an `Ecto.Type` failure arm is
  # the easiest place in this package to leak a plaintext, and the least
  # excusable. The same rule, and the same vocabulary, as
  # `Encryptor.Ecto.Map`'s own refusal.
  @spec refuse!(module(), kind(), Binary.params(), term()) :: no_return()
  defp refuse!(impl, kind, params, value) do
    raise ArgumentError,
          "#{params.table}.#{params.column}: dump/3 expects #{expected(kind)} or nil " <>
            "for #{inspect(impl)}, and was given #{shape_of(value)}. Its value is " <>
            "deliberately not reported. A value that reached dump/3 without passing " <>
            "cast/2 is wrong in the source rather than at runtime."
  end

  @spec expected(kind()) :: String.t()
  defp expected(:integer), do: "an integer"
  defp expected(:float), do: "a float"
  defp expected(:date), do: "a Date"
  defp expected(:time), do: "a Time"
  defp expected(:naive_datetime), do: "a NaiveDateTime"
  defp expected(:utc_datetime), do: "a DateTime in Etc/UTC"

  @spec shape_of(term()) :: String.t()
  defp shape_of(%module{}), do: "a #{inspect(module)} struct"
  defp shape_of(value) when is_atom(value), do: "an atom"
  defp shape_of(value) when is_integer(value), do: "an integer"
  defp shape_of(value) when is_float(value), do: "a float"
  defp shape_of(value) when is_binary(value), do: "a binary"
  defp shape_of(value) when is_list(value), do: "a list"
  defp shape_of(value) when is_map(value), do: "a map"
  defp shape_of(value) when is_tuple(value), do: "a tuple"
  defp shape_of(_value), do: "a term of another type"
end
