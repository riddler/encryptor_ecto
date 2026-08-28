defmodule Encryptor.Ecto.Map do
  @moduledoc """
  An encrypted map field: `Encryptor.Ecto.Binary` over a serialized map
  (ADR-0001 decisions 1 and 8).

      defmodule Payments.Encrypted.Map do
        use Encryptor.Ecto.Map, vault: Payments.Vault
      end

      defmodule Payments.Cards.Card do
        use Ecto.Schema

        schema "cards" do
          field :merchant_id, :string
          field :metadata, Payments.Encrypted.Map
        end
      end

  Everything below the serializer is `Encryptor.Ecto.Binary`, called rather
  than copied: the same closed option set plus `:json`, the same declared
  `"table"`/`"column"` context, the same tenant resolution, the same `:binary`
  column, the same exception family, and the vault's bytes stored verbatim.
  Read that module for all of it; only the differences are documented here.

  ## The serializer, and `:json`

  `:json` names any module exporting `encode!/1` and `decode!/1`, and defaults
  to `Jason` (decision 8). It is checked at `init/2` rather than assumed, so a
  declaration naming a module that cannot serialize fails where the field is
  declared instead of on the first write of a production row.

  The serializer runs on the *plaintext* side of the vault call - encoding
  before the dump, decoding after the load - so its failure is neither an
  encryption failure nor an integrity event, and it raises
  `Encryptor.Ecto.SerializationError` rather than being folded into either.
  Like every exception in the family, it carries the declared table, the
  declared column and the context key names and no value: a serialization
  failure is the point in this package where a plaintext is closest to hand.

  Two arms go slightly beyond what decision 6's table enumerates, and both are
  noted rather than assumed. A payload the serializer *parsed successfully*
  into something that is not a map raises the same exception with a
  `{:not_a_map, tag}` reason - it is a deserialization result the type cannot
  return, and calling it an integrity event would blame the vault for a
  serializer's answer. And a `:json` module that is not loadable, or does not
  export both functions, is refused at `init/2` rather than at the first write;
  decision 3 makes unknown *options* a compile-time error and says nothing
  about an option's value, so this is a fail-fast extension of it.

  Its `:tenant` field is `nil` even on the decode side, where one *was*
  resolved. This layer resolves no tenant of its own - `Binary` does, inside
  the call this one wraps - and reporting a tenant it would have to re-resolve
  to know is a second source of truth for the value the whole encryption
  context turns on.

  ## A loaded map has string keys

  Which is what `:map`-typed Ecto columns already do. Atom keys are not
  offered, and adding them later would not be a bug fix: `String.to_existing_atom/1`
  fails on a key whose atom the loading node has not created, and the
  alternative is an unbounded-atom hazard driven by stored data.

  The consequence a host meets first: a map cast with atom keys dumps fine and
  loads back with string keys, so `%{channel: "web"}` in and
  `%{"channel" => "web"}` out. `cast/2` does not silently rewrite the keys to
  hide it - `Ecto`'s own `:map` type does not either, and a normalization that
  happens in one direction only is harder to reason about than the asymmetry it
  conceals. Declare the map with string keys and the round trip is exact.

  Decision 8 states this as "always", and with the default serializer it is:
  `Jason` produces string keys and nothing here can change that. It is **not
  verified** for a host-supplied `:json`, which the same decision permits to be
  any module exporting `encode!/1` and `decode!/1`. `load/3` checks that the
  payload deserialized into a map and stops there - walking every key of every
  loaded map on every read is a per-row cost, and refusing one would be a
  failure class decision 6's table does not list. A host naming its own
  serializer is trusted to honour the rule, and this says so rather than
  repeating a guarantee the code does not enforce.

  ## Structs are refused at `cast/2`, and the record does not settle it

  A struct is a map, and this type rejects one anyway. Stated plainly, because
  it is a choice rather than a citation: decision 6 gives "a non-map handed to
  `Map`" as the cast failure, and on a literal reading a struct is not that.
  Decision 8 leans the other way - "a host wanting struct fidelity uses an
  embedded schema over `Encryptor.Ecto.Map`, not a smarter serializer" - but
  neither settles the arm.

  Refusing is the reading taken here, for one reason: a struct that *does*
  carry a `Jason.Encoder` round-trips to a plain map silently, on every read.
  It is also the direction that is cheap to undo - relaxing `cast/2` later
  breaks no host, while tightening it later breaks every host that had been
  passing structs. If the operator rules the other way, the change is one
  guard on one clause.

  ## `:erlang.term_to_binary/1` is refused, on the record

  It makes the payload a deserialization surface, ties the stored bytes to the
  BEAM, and would let a successfully-authenticated-but-hostile payload
  construct arbitrary terms. Encrypted bytes are still bytes that may have come
  from a restore of somebody else's backup, so the deserializer stays boring on
  purpose (decision 8).

  ## `nil`, and empty

  `nil` dumps and loads as `nil` with no encryption, and `%{}` is *not* `nil`:
  it is serialized, encrypted, and round-trips as `%{}` (decision 7). The
  distinction between "no value" and "empty value" is the host's to make and
  this layer preserves it exactly.
  """

  alias Encryptor.Ecto.Binary
  alias Encryptor.Ecto.SerializationError

  @default_serializer Jason

  @typedoc """
  The options `use Encryptor.Ecto.Map` accepts.

  `Encryptor.Ecto.Binary`'s set plus `:json`, which is Map-only (decision 3).
  """
  @type opts :: [
          {:json, module()}
          | {:vault, module()}
          | {:tenant, :scope | :none | module()}
          | {:context, %{optional(String.t()) => String.t()}}
          | {:legacy, module()}
          | {:table, String.t()}
          | {:column, String.t()}
        ]

  @typedoc "What `init/2` freezes: `Encryptor.Ecto.Binary`'s params plus the serializer."
  @type params :: %{
          vault: module(),
          tenant: :scope | :none | module(),
          context: %{optional(String.t()) => String.t()},
          table: String.t(),
          column: String.t(),
          json: module()
        }

  @doc """
  Defines an encrypted map type on the using module.

  See `Encryptor.Ecto.Binary` for the shared option set, and `:json` above;
  anything outside the two raises here, while the host module is compiling.
  """
  @spec __using__(opts()) :: Macro.t()
  defmacro __using__(opts) do
    # Named by an unquoted module atom rather than written out, so nothing here
    # injects an alias into the host's namespace on its way past. Every
    # callback is this module's: even the ones that only forward have to strip
    # `:json` back out before `Binary` sees the params.
    impl = __MODULE__

    quote do
      @behaviour Ecto.ParameterizedType

      @encryptor_ecto_declared unquote(impl).validate_declaration!(__MODULE__, unquote(opts))

      @doc false
      @impl Ecto.ParameterizedType
      def init(field_opts),
        do: unquote(impl).init(@encryptor_ecto_declared, field_opts)

      @doc false
      @impl Ecto.ParameterizedType
      def type(params), do: unquote(impl).type(params)

      @doc false
      @impl Ecto.ParameterizedType
      def cast(value, params), do: unquote(impl).cast(value, params)

      @doc false
      @impl Ecto.ParameterizedType
      def dump(value, dumper, params), do: unquote(impl).dump(value, dumper, params)

      @doc false
      @impl Ecto.ParameterizedType
      def load(value, loader, params), do: unquote(impl).load(value, loader, params)

      @doc false
      @impl Ecto.ParameterizedType
      def equal?(left, right, params), do: unquote(impl).equal?(left, right, params)

      @doc false
      @impl Ecto.ParameterizedType
      def embed_as(format, params), do: unquote(impl).embed_as(format, params)
    end
  end

  @doc """
  Checks a declaration's option set while the declaring module compiles.

      iex> Encryptor.Ecto.Map.validate_declaration!(Payments.Encrypted.Map,
      ...>   vault: Payments.Vault,
      ...>   json: Jason
      ...> )
      [vault: Payments.Vault, json: Jason]
  """
  @spec validate_declaration!(module(), keyword()) :: keyword()
  def validate_declaration!(module, opts),
    do: Binary.validate_declaration!(module, opts, __MODULE__, [:json])

  @doc """
  Freezes the declared context and the serializer.

  `Encryptor.Ecto.Binary.init/2` does the first half - the option validation,
  the tenant strategy, and the `"table"`/`"column"` derivation - and the
  serializer is resolved and checked here.
  """
  @spec init(keyword(), keyword()) :: params()
  def init(declared, field_opts) do
    params = Binary.init(declared, field_opts)
    Elixir.Map.put(params, :json, validated_serializer!(declared, params))
  end

  @doc """
  The column type, which is `:binary` - a serialized map is bytes like any
  other plaintext (decision 2).

      iex> Encryptor.Ecto.Map.type(%{})
      :binary
  """
  @spec type(term()) :: :binary
  def type(params), do: Binary.type(binary_params(params))

  @doc """
  Casts a value on its way into a changeset. Never encrypts, never serializes.

  Accepts `nil` and a plain map; a non-map is a validation failure (decision
  6), and so is a struct, which could not round-trip.

      iex> Encryptor.Ecto.Map.cast(%{"channel" => "web"}, %{})
      {:ok, %{"channel" => "web"}}

      iex> Encryptor.Ecto.Map.cast(%{}, %{})
      {:ok, %{}}

      iex> Encryptor.Ecto.Map.cast(nil, %{})
      {:ok, nil}

      iex> Encryptor.Ecto.Map.cast("channel=web", %{})
      :error

      iex> Encryptor.Ecto.Map.cast(%URI{}, %{})
      :error
  """
  @spec cast(term(), term()) :: {:ok, map() | nil} | :error
  def cast(nil, _params), do: {:ok, nil}
  def cast(value, _params) when is_map(value) and not is_struct(value), do: {:ok, value}
  def cast(_value, _params), do: :error

  @doc """
  Serializes a map and encrypts the result.

  `nil` passes through unencrypted. There is no `:error` arm: a serializer
  failure raises `Encryptor.Ecto.SerializationError` and every failure below it
  raises whatever `Encryptor.Ecto.Binary.dump/3` raises (decision 6).
  """
  @spec dump(term(), function(), params()) :: {:ok, binary() | nil}
  def dump(nil, _dumper, _params), do: {:ok, nil}

  def dump(value, dumper, params) when is_map(value) and not is_struct(value) do
    Binary.dump(encode!(value, params), dumper, binary_params(params))
  end

  def dump(value, _dumper, params), do: refuse_non_map!(params, value)

  @doc """
  Decrypts the stored bytes and deserializes them back into a map.

  `nil` passes through. A decrypt failure is `Encryptor.Ecto.Binary`'s to
  raise; a payload that decrypts and then fails to parse, or that parses into
  something other than a map, is `Encryptor.Ecto.SerializationError`.
  """
  @spec load(term(), function(), params()) :: {:ok, map() | nil}
  def load(nil, _loader, _params), do: {:ok, nil}

  def load(value, loader, params) when is_binary(value) do
    {:ok, plaintext} = Binary.load(value, loader, binary_params(params))
    {:ok, decode!(plaintext, params)}
  end

  # Anything else is not a stored value at all, and `Binary.load/3`'s own
  # catch-all refuses it by shape without rendering it - the same message, from
  # the module that owns the rule.
  def load(value, loader, params), do: Binary.load(value, loader, binary_params(params))

  @doc """
  Compares plaintext maps, never stored bytes (decision 9).

      iex> Encryptor.Ecto.Map.equal?(%{"channel" => "web"}, %{"channel" => "web"}, %{})
      true
  """
  @spec equal?(term(), term(), term()) :: boolean()
  def equal?(left, right, params), do: Binary.equal?(left, right, binary_params(params))

  @doc """
  Embeds as the cast value rather than the dumped one (decision 9).

      iex> Encryptor.Ecto.Map.embed_as(:json, %{})
      :self
  """
  @spec embed_as(atom(), term()) :: :self
  def embed_as(format, params), do: Binary.embed_as(format, binary_params(params))

  # -- the serializer -------------------------------------------------------

  @spec encode!(map(), params()) :: binary()
  defp encode!(value, params) do
    case run(fn -> params.json.encode!(value) end) do
      {:ok, encoded} -> encoded
      {:error, reason} -> raise SerializationError, detail(params, :encode, reason)
    end
  end

  @spec decode!(binary(), params()) :: map()
  defp decode!(plaintext, params) do
    case run(fn -> params.json.decode!(plaintext) end) do
      {:ok, decoded} when is_map(decoded) and not is_struct(decoded) ->
        decoded

      {:ok, decoded} ->
        raise SerializationError, detail(params, :decode, {:not_a_map, shape_tag(decoded)})

      {:error, reason} ->
        raise SerializationError, detail(params, :decode, reason)
    end
  end

  # The serializer's contract is `encode!/1` and `decode!/1` - it raises rather
  # than returning a result - so this is where a raise becomes the `{:ok, v} |
  # {:error, reason}` the rest of the package speaks. Nothing is swallowed: the
  # caller raises on every `:error`, and it raises from outside the rescue so
  # the failing serializer's own stacktrace is not carried into the exception a
  # host sees.
  @spec run((-> term())) :: {:ok, term()} | {:error, {:serializer_raised, module()}}
  defp run(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:error, {:serializer_raised, exception.__struct__}}
  end

  # The rescued exception is reduced to its *module* and discarded, because a
  # serializer's own error struct carries the offending term. Checked against
  # the default rather than assumed: `Jason.DecodeError` holds the whole
  # payload in `:data`, `Jason.EncodeError`'s message inspects the binary it
  # choked on, and the `Protocol.UndefinedError` Jason raises for an
  # unencodable term holds it in `:value`. Re-raising one of those, or folding
  # its message in, would put a plaintext into a failure report through the
  # back door ADR-0001 decision 6 closes at the front.
  @spec detail(params(), :encode | :decode, term()) :: keyword()
  defp detail(params, direction, reason) do
    binary = binary_params(params)

    [
      table: params.table,
      column: params.column,
      context_keys: Binary.context_keys(binary),
      tenant: nil,
      reason: reason,
      serializer: params.json,
      direction: direction
    ]
  end

  # `Binary`'s callbacks are specced over `Encryptor.Ecto.Binary.params()`,
  # which is exactly its five keys. `:json` is this layer's and is stripped
  # before it crosses, so the contract between the two is the declared one
  # rather than "a superset happens to work".
  @spec binary_params(params()) :: Binary.params()
  defp binary_params(params), do: Elixir.Map.delete(params, :json)

  @spec validated_serializer!(keyword(), Binary.params()) :: module()
  defp validated_serializer!(declared, params) do
    module = Keyword.get(declared, :json, @default_serializer)

    cond do
      not is_atom(module) or is_nil(module) ->
        raise ArgumentError, serializer_message(params, module, "is not a module")

      # `Code.ensure_loaded?/1` before `function_exported?/2` is not defensive
      # noise: `function_exported?/2` answers false for a module that is merely
      # not loaded yet, which under lazy loading is the ordinary case for a
      # serializer this process has not called. Without it a declaration would
      # be refused for a reason that depends on load order. Not hypothetical:
      # in a fresh `mix run`, `function_exported?(Jason, :encode!, 1)` answers
      # false until something loads Jason, and the default serializer would be
      # rejected on a machine where nothing had.
      not Code.ensure_loaded?(module) ->
        raise ArgumentError, serializer_message(params, module, "could not be loaded")

      not (function_exported?(module, :encode!, 1) and function_exported?(module, :decode!, 1)) ->
        raise ArgumentError,
              serializer_message(params, module, "does not export both encode!/1 and decode!/1")

      true ->
        module
    end
  end

  # -- messages -------------------------------------------------------------

  # Named the way every other message in this package names a field: by the
  # declared table and column, which `Binary.init/2` has already frozen by the
  # time this check runs.
  defp serializer_message(params, module, complaint) do
    """
    #{params.table}.#{params.column}: the :json serializer #{inspect(module)} #{complaint}.

    It must be a module exporting encode!/1 and decode!/1 (ADR-0001 decision \
    8). The default is #{inspect(@default_serializer)}. The check runs at the \
    declaration rather than at the first write, because a serializer that \
    cannot serialize is a compile-time mistake wherever it is discovered.
    """
  end

  # The value is never rendered, only its shape - an `Ecto.Type` failure arm is
  # the easiest place in this package to leak a plaintext, and the least
  # excusable.
  @spec refuse_non_map!(params(), term()) :: no_return()
  defp refuse_non_map!(params, value) do
    raise ArgumentError,
          "#{params.table}.#{params.column}: dump/3 expects a plain map or nil, " <>
            "and was given #{shape_of(value)}. Its value is deliberately not reported. " <>
            "A value that reached dump/3 without passing cast/2 is wrong in the " <>
            "source rather than at runtime."
  end

  # A reason field carries the atom tag rather than the phrase, because
  # `Encryptor.Ecto.Error.redact/1` renders any binary as its byte count: a
  # reason of `{:not_a_map, "a list"}` reaches a host as
  # `{:not_a_map, <<redacted 6 bytes>>}`, losing exactly the detail the arm
  # exists to give. Atoms and tuples of atoms survive redaction verbatim.
  @spec shape_tag(term()) :: atom() | {:struct, module()}
  defp shape_tag(%module{}), do: {:struct, module}
  defp shape_tag(value) when is_atom(value), do: :atom
  defp shape_tag(value) when is_integer(value), do: :integer
  defp shape_tag(value) when is_float(value), do: :float
  defp shape_tag(value) when is_binary(value), do: :binary
  defp shape_tag(value) when is_list(value), do: :list
  defp shape_tag(value) when is_tuple(value), do: :tuple
  defp shape_tag(_value), do: :other

  # The readable half, for the `ArgumentError`, which is not a member of the
  # redacting exception family and renders its own message.
  @spec shape_of(term()) :: String.t()
  defp shape_of(value), do: value |> shape_tag() |> phrase()

  defp phrase({:struct, module}), do: "a #{inspect(module)} struct"
  defp phrase(:atom), do: "an atom"
  defp phrase(:integer), do: "an integer"
  defp phrase(:float), do: "a float"
  defp phrase(:binary), do: "a binary"
  defp phrase(:list), do: "a list"
  defp phrase(:tuple), do: "a tuple"
  defp phrase(:other), do: "a term of another type"
end
