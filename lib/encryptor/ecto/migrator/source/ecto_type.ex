defmodule Encryptor.Ecto.Migrator.Source.EctoType do
  @moduledoc """
  Adapts any module that can already read a column's bytes to
  `Encryptor.Ecto.Migrator.Source`.

  ADR-0004 decision 2. The adapted module is the host's own type module - the
  one it has been running in production, with the host's cipher
  configuration, the host's key material and the host's own test suite behind
  it. That is the whole point of the indirection, and it is why nothing here
  knows what a `cloak_ecto` message looks like.

  The two shapes it adapts:

    * arity-1 `load/1` - a plain `Ecto.Type`, which is every `cloak_ecto` type
      module and every hand-rolled one. Ecto's contract for it is
      `{:ok, value} | :error`;
    * arity-3 `load/3` - an `Ecto.ParameterizedType`. The migrator's own
      per-field params are passed through to it verbatim (ADR-0002 decision
      3), minus this adapter's two keys, and the loader is `Ecto.Type.load/2`
      so an embedded or composite legacy type still resolves the way Ecto
      would resolve it.

  Which of the two is used is decided by
  `Encryptor.Ecto.Migrator.Source.resolve!/2` while the plan compiles, and
  travels here as `:source_arity`. It is not re-derived per row: a
  `function_exported?/3` call on every row of a million-row pass would be a
  cost paid to answer a question that cannot change during the pass.

  ## Converting a failure into data

  ADR-0001 decision 6 makes the types raise. A migrator cannot work that way -
  it has to classify the row `:undecryptable`, record it, and go on (ADR-0002
  decisions 7 and 11) - so this adapter converts:

    * an `:error` return, which is what a `cloak_ecto` type gives on a failed
      decrypt, becomes `{:error, :load_failed}`;
    * a raise from the adapted module becomes `{:error, {:raised, Module}}`.

  The rescue is scoped to the single `load` call on a single row. It is not a
  rescue-to-default at a leaf: nothing proceeds with a substituted value, the
  row is classified as unreadable, and ADR-0002 decision 11's default is
  still to halt the pass. The reason carries the raising module's name and
  nothing else, for the redaction reason
  `Encryptor.Ecto.Migrator.Source` states in full.

  A `throw` or an `exit` from an adapted module is deliberately not caught. A
  type that throws is not failing to decrypt, it is misbehaving, and a
  migrator that swallowed it would be inventing a classification for
  something it does not understand.
  """

  alias Encryptor.Ecto.Migrator.Source

  @behaviour Source

  @adapter_keys [:source_module, :source_arity]

  @typedoc "The keys `Encryptor.Ecto.Migrator.Source.resolve!/2` fixes here."
  @type adapter_params :: %{source_module: module(), source_arity: 1 | 3}

  @doc """
  Reads one row's pre-migration bytes through the adapted module.

  `:source_module` and `:source_arity` are supplied by the resolution and are
  dropped before the remaining params reach an arity-3 adapted module.
  """
  @impl Source
  @spec load(binary(), Source.params()) :: {:ok, term()} | {:error, term()}
  def load(value, %{source_module: module, source_arity: arity} = params) do
    adapted(module, arity, value, Map.drop(params, @adapter_keys))
  end

  @spec adapted(module(), 1 | 3, binary(), Source.params()) ::
          {:ok, term()} | {:error, term()}
  defp adapted(module, 1, value, _params) do
    normalize(module.load(value))
  rescue
    exception -> {:error, {:raised, exception.__struct__}}
  end

  defp adapted(module, 3, value, params) do
    normalize(module.load(value, &Ecto.Type.load/2, params))
  rescue
    exception -> {:error, {:raised, exception.__struct__}}
  end

  # Never a bare `case` with no catch-all: the unmatched term in a
  # CaseClauseError message is the plaintext.
  @spec normalize(term()) :: {:ok, term()} | {:error, term()}
  defp normalize({:ok, loaded}), do: {:ok, loaded}
  defp normalize(:error), do: {:error, :load_failed}
  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize(_other), do: {:error, :invalid_source_result}
end
