defmodule Encryptor.Ecto.Error do
  @moduledoc """
  The shared shape, and the redaction rules, of the encrypted-field exception
  family (ADR-0001 decision 6, acceptance amendment 2).

  Every exception this package raises from `dump/3` and `load/3` carries the
  same four identifying values - the declared table, the declared column, the
  encryption-context *keys*, and the upstream reason - plus the tenant
  identifier where one was resolved. Individual exceptions add a field or two
  of their own; none of them adds a value.

  ## The prohibition this module exists to enforce

  > No exception message, log line, or `Exception.message/1` ever includes
  > plaintext, ciphertext bytes, or key material - including in the `Inspect`
  > implementation of the exception struct.

  That is ADR-0001 decision 6, and it is a decision rather than a review
  preference. It is enforced structurally here rather than by convention in
  five separate modules: `__using__/1` defines the struct, `message/1`, *and*
  an `Inspect` implementation that replaces the derived one, so an exception
  in this family cannot be added without the override.

  The mechanism is `redact/1`, which renders a term the upstream vault
  supplied. Only atoms and integers survive it verbatim; tuples and lists are
  rendered structurally with each element redacted in turn; a binary is
  reduced to its byte count and everything else to a bare marker. The rule is
  deliberately about the *shape* of a term rather than about where it came
  from, because a vault `:reason` is an opaque term this layer cannot inspect
  for secrets - a binary in one is as likely to be a ciphertext fragment as a
  message.

  The declared table, the declared column and the context keys are *not*
  redacted: they are declaration-time strings, they are what makes a failure
  diagnosable, and the bead's rule names them as carried. The tenant
  identifier is likewise rendered, as the one value the prohibition exempts.

  ## The cost, stated

  Redaction by shape loses operator-facing detail that happens to be a binary.
  `{:encryption_context_mismatch, "table"}` in a `DecryptError`'s `:engine`
  field renders its tag and the byte count of its key name, not the key name.
  The alternative - a heuristic that lets "short, printable" binaries through -
  passes a three-character plaintext, so the structural rule is the one that
  holds.

  ## Where the guarantee stops

  It covers every *rendering* this layer controls: `Exception.message/1`,
  `Exception.format/3` and the stacktrace it prints, and `Kernel.inspect/2`.

  It does not cover a caller who deliberately steps around the `Inspect`
  protocol - `inspect(error, structs: false)`, or `Map.from_struct/1` followed
  by anything. Those bypass every implementation in the system, `Ecto`'s own
  `@derive Inspect` redaction included, and no implementation can defend
  against them. The `:reason` field holds the vault's term rather than a
  pre-rendered string precisely so that a caller can still match on it, which
  is what leaves the term reachable at all.
  """

  @typedoc """
  The identifying values every exception in the family carries.

  `:context_keys` are encryption-context key *names*; the context's values are
  never carried. `:tenant` is the resolved tenant identifier, the single value
  ADR-0001 decision 6 exempts from the prohibition.
  """
  @type common :: [
          table: String.t() | nil,
          column: String.t() | nil,
          context_keys: [String.t()],
          tenant: term(),
          reason: term()
        ]

  @typedoc "A rendered `label: value` pair, ready to join into a detail list."
  @type detail :: {String.t(), String.t()}

  @doc """
  Defines one member of the exception family.

  Injects the common struct fields, an `Exception` implementation whose
  `message/1` renders the headline and the detail list, and an `Inspect`
  implementation that replaces the derived one. `:extra_fields` adds
  struct fields beyond the common set.

  The using module must define `headline/0`. It may define `extra_detail/1`,
  returning `t:detail/0` pairs appended to the common ones; the default
  returns none.
  """
  defmacro __using__(opts) do
    extra_fields = Keyword.get(opts, :extra_fields, [])

    fields =
      [table: nil, column: nil, context_keys: [], tenant: nil, reason: nil] ++ extra_fields

    quote bind_quoted: [fields: fields] do
      # Deliberately leaked into the using module: it is what lets the
      # generated bodies, and the using module's own extra_detail/1, name the
      # redaction helpers without repeating the full path.
      alias Encryptor.Ecto.Error

      defexception fields

      @typedoc "An exception in the encrypted-field family."
      @type t :: %__MODULE__{}

      @doc false
      @impl Exception
      @spec message(t()) :: String.t()
      def message(%__MODULE__{} = error) do
        Error.render_message(
          headline(),
          Error.common_detail(error) ++ extra_detail(error)
        )
      end

      @doc false
      @spec extra_detail(t()) :: [Error.detail()]
      def extra_detail(%__MODULE__{}), do: []

      defoverridable extra_detail: 1

      defimpl Inspect do
        import Kernel, except: [inspect: 2]

        alias Encryptor.Ecto.Error

        def inspect(%mod{} = error, _opts) do
          Error.render_inspect(mod, Error.common_detail(error) ++ mod.extra_detail(error))
        end
      end
    end
  end

  @doc """
  Renders a term supplied by the vault, keeping plaintext, ciphertext bytes and
  key material out of the result.

  Atoms and integers render as themselves. Tuples and lists render
  structurally, with every element redacted in turn. A binary renders as its
  byte count, and any other term as a bare marker.

      iex> Encryptor.Ecto.Error.redact(:decrypt_failed)
      ":decrypt_failed"

      iex> Encryptor.Ecto.Error.redact({:missing_required_context_keys, [:table]})
      "{:missing_required_context_keys, [:table]}"

      iex> Encryptor.Ecto.Error.redact("4111111111111111")
      "<<redacted 16 bytes>>"

      iex> Encryptor.Ecto.Error.redact(%{card_number: "4111111111111111"})
      "<redacted>"
  """
  @spec redact(term()) :: String.t()
  def redact(term) when is_atom(term), do: inspect(term)
  def redact(term) when is_integer(term), do: Integer.to_string(term)
  def redact(term) when is_binary(term), do: "<<redacted #{byte_size(term)} bytes>>"

  def redact(term) when is_list(term),
    do: "[" <> Enum.map_join(term, ", ", &redact/1) <> "]"

  def redact(term) when is_tuple(term),
    do: "{" <> Enum.map_join(Tuple.to_list(term), ", ", &redact/1) <> "}"

  def redact(_term), do: "<redacted>"

  @doc """
  The rendered detail pairs every exception in the family carries.
  """
  @spec common_detail(struct()) :: [detail()]
  def common_detail(error) do
    [
      {"table", inspect(error.table)},
      {"column", inspect(error.column)},
      {"context keys", inspect(error.context_keys)},
      {"tenant", inspect(error.tenant)},
      {"reason", redact(error.reason)}
    ]
  end

  @doc """
  Renders a headline and its detail pairs as an `Exception.message/1` result.
  """
  @spec render_message(String.t(), [detail()]) :: String.t()
  def render_message(headline, details) do
    headline <> " (" <> join_details(details) <> ")"
  end

  @doc """
  Renders detail pairs as the `Inspect` form of an exception struct.

  Deliberately not the derived form: the derived one prints every field with
  `Inspect` defaults, which is precisely what ADR-0001 decision 6 forbids.
  """
  @spec render_inspect(module(), [detail()]) :: String.t()
  def render_inspect(module, details) do
    "#" <> inspect(module) <> "<" <> join_details(details) <> ">"
  end

  @spec join_details([detail()]) :: String.t()
  defp join_details(details) do
    Enum.map_join(details, ", ", fn {label, value} -> "#{label}: #{value}" end)
  end
end
