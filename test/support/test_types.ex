defmodule Encryptor.Ecto.TestTypes do
  @moduledoc """
  The host type modules the tests declare fields with.

  One module per declaration shape the bead has to cover: the default
  `tenant: :scope`, a `tenant: :none` global field on the single-key vault, a
  host resolver module, and a declaration whose context values are pinned
  rather than derived.
  """

  defmodule Pan do
    @moduledoc "The ordinary case: a per-merchant field on the tenant vault."

    use Encryptor.Ecto.Binary, vault: Encryptor.Ecto.TestVaults.Merchant
  end

  defmodule Notes do
    @moduledoc "A second field in the same table, to show the column separates them."

    use Encryptor.Ecto.Binary, vault: Encryptor.Ecto.TestVaults.Merchant
  end

  defmodule Global do
    @moduledoc "A field declared global, on a `:single`-profile vault."

    use Encryptor.Ecto.Binary,
      vault: Encryptor.Ecto.TestVaults.App,
      tenant: :none
  end

  defmodule Misprofiled do
    @moduledoc """
    A global field pointed at the `:tenant`-profile vault - the pairing
    ADR-0001 decision 5e forbids, and the subject of the rule's raise.
    """

    use Encryptor.Ecto.Binary,
      vault: Encryptor.Ecto.TestVaults.Merchant,
      tenant: :none
  end

  defmodule MisprofiledUnstarted do
    @moduledoc """
    A global field on a vault that is never started, so the profile check has
    no frozen configuration to read and must defer to the vault's own
    not-started refusal.
    """

    use Encryptor.Ecto.Binary,
      vault: Encryptor.Ecto.TestVaults.Unstarted,
      tenant: :none
  end

  defmodule Resolved do
    @moduledoc "A field whose tenant comes from a host resolver rather than the scope."

    use Encryptor.Ecto.Binary,
      vault: Encryptor.Ecto.TestVaults.Merchant,
      tenant: Encryptor.Ecto.TestResolvers.Fixed
  end

  defmodule Declining do
    @moduledoc "A field whose resolver answers :none, the behaviour's global arm."

    use Encryptor.Ecto.Binary,
      vault: Encryptor.Ecto.TestVaults.App,
      tenant: Encryptor.Ecto.TestResolvers.Declining
  end

  defmodule Refusing do
    @moduledoc "A field whose resolver always fails, so the load-side raise has a subject."

    use Encryptor.Ecto.Binary,
      vault: Encryptor.Ecto.TestVaults.Merchant,
      tenant: Encryptor.Ecto.TestResolvers.Refusing
  end

  defmodule OffContract do
    @moduledoc "A field whose resolver answers outside the behaviour's contract."

    use Encryptor.Ecto.Binary,
      vault: Encryptor.Ecto.TestVaults.Merchant,
      tenant: Encryptor.Ecto.TestResolvers.OffContract
  end

  defmodule Pinned do
    @moduledoc "A field whose declared context is pinned rather than derived."

    use Encryptor.Ecto.Binary,
      vault: Encryptor.Ecto.TestVaults.Merchant,
      table: "cards",
      column: "pan",
      context: %{"purpose" => "pii"}
  end

  defmodule Strict do
    @moduledoc "A global field on a vault that requires a key this type does not supply."

    use Encryptor.Ecto.Binary,
      vault: Encryptor.Ecto.TestVaults.Strict,
      tenant: :none
  end

  defmodule Unstarted do
    @moduledoc "A field pointing at a vault nothing ever starts."

    use Encryptor.Ecto.Binary, vault: Encryptor.Ecto.TestVaults.Unstarted
  end

  defmodule HolderName do
    @moduledoc "A text field: `Encryptor.Ecto.String`'s ordinary case."

    use Encryptor.Ecto.String, vault: Encryptor.Ecto.TestVaults.Merchant
  end

  defmodule GlobalName do
    @moduledoc "A text field with no tenant, to show String carries Binary's whole option set."

    use Encryptor.Ecto.String,
      vault: Encryptor.Ecto.TestVaults.App,
      tenant: :none
  end

  defmodule Metadata do
    @moduledoc "A map field on the default serializer."

    use Encryptor.Ecto.Map, vault: Encryptor.Ecto.TestVaults.Merchant
  end

  defmodule Sorted do
    @moduledoc "A map field naming its own serializer rather than taking the default."

    use Encryptor.Ecto.Map,
      vault: Encryptor.Ecto.TestVaults.Merchant,
      json: Encryptor.Ecto.TestSerializers.Sorted
  end

  defmodule Unserializable do
    @moduledoc "A map field whose serializer raises in both directions."

    use Encryptor.Ecto.Map,
      vault: Encryptor.Ecto.TestVaults.Merchant,
      json: Encryptor.Ecto.TestSerializers.Failing
  end

  defmodule Listy do
    @moduledoc "A map field whose serializer decodes to something that is not a map."

    use Encryptor.Ecto.Map,
      vault: Encryptor.Ecto.TestVaults.Merchant,
      json: Encryptor.Ecto.TestSerializers.Listy
  end
end

defmodule Encryptor.Ecto.TestSerializers do
  @moduledoc """
  Serializer modules for `Encryptor.Ecto.Map`, one per arm of decision 8's
  contract: a working alternative to the default, one that raises, and one that
  parses into something other than a map.

  None of them renders the value it was given. A serializer failure is the
  point in this package where a plaintext is closest to hand, and a fixture
  that printed one would leak it into exactly the failure report the type's own
  code is careful not to write.
  """

  defmodule Sorted do
    @moduledoc "A working serializer that is demonstrably not the default."

    @doc """
    Encodes with the keys in sorted order, so its output is byte-for-byte
    distinguishable from the default's on a map whose key order is not sorted.
    """
    @spec encode!(term()) :: String.t()
    def encode!(term) do
      pairs =
        term
        |> Enum.sort()
        |> Enum.map_join(",", fn {key, value} ->
          Jason.encode!(to_string(key)) <> ":" <> Jason.encode!(value)
        end)

      "{" <> pairs <> "}"
    end

    @doc "Decodes exactly as the default does."
    @spec decode!(binary()) :: term()
    def decode!(binary), do: Jason.decode!(binary)
  end

  defmodule Failing do
    @moduledoc "A serializer that raises in both directions."

    @doc "Always raises, without rendering the term."
    @spec encode!(term()) :: no_return()
    def encode!(_term), do: raise(RuntimeError, "the serializer declined")

    @doc "Always raises, without rendering the bytes."
    @spec decode!(binary()) :: no_return()
    def decode!(_binary), do: raise(RuntimeError, "the serializer declined")
  end

  defmodule Listy do
    @moduledoc "A serializer whose decode answers with a list rather than a map."

    @doc "Encodes the way the default does."
    @spec encode!(term()) :: String.t()
    def encode!(term), do: Jason.encode!(term)

    @doc "Answers with a list whatever it was given."
    @spec decode!(binary()) :: list()
    def decode!(_binary), do: ["not", "a", "map"]
  end

  defmodule Halfway do
    @moduledoc "A module exporting only half the serializer contract."

    @doc "The only half this module has."
    @spec encode!(term()) :: String.t()
    def encode!(term), do: Jason.encode!(term)
  end
end

defmodule Encryptor.Ecto.TestResolvers do
  @moduledoc "Host-supplied tenant resolvers, covering each arm of the callback's contract."

  defmodule Fixed do
    @moduledoc "Answers with one merchant, whatever the process scope holds."

    @behaviour Encryptor.Ecto.TenantContext

    @doc "Always the same merchant."
    @impl Encryptor.Ecto.TenantContext
    def resolve(_operation, _params), do: {:ok, "merchant_7f3"}
  end

  defmodule Declining do
    @moduledoc "Answers that this value has no tenant at all."

    @behaviour Encryptor.Ecto.TenantContext

    @doc "Declares the value global, the way `tenant: :none` does at the field."
    @impl Encryptor.Ecto.TenantContext
    def resolve(_operation, _params), do: :none
  end

  defmodule Refusing do
    @moduledoc "Answers that it could not resolve, which the type must raise on."

    @behaviour Encryptor.Ecto.TenantContext

    @doc "Never resolves."
    @impl Encryptor.Ecto.TenantContext
    def resolve(operation, _params), do: {:error, {:no_request_context, operation}}
  end

  defmodule OffContract do
    @moduledoc "Answers with something the callback's contract does not allow."

    @doc "Returns a bare atom rather than a result."
    def resolve(_operation, _params), do: :whatever
  end
end

defmodule Encryptor.Ecto.TestSchemas do
  @moduledoc "Schemas the database-backed tests read and write."

  defmodule Card do
    @moduledoc """
    A card row: a queryable merchant reference and two encrypted columns.

    The schema names the host's type modules and nothing about it says
    `encryptor` - which is the property ADR-0001's migration story rests on.
    """

    use Ecto.Schema

    @type t :: %__MODULE__{}

    schema "cards" do
      field(:merchant_id, :string)
      field(:pan, Encryptor.Ecto.TestTypes.Pan)
      field(:notes, Encryptor.Ecto.TestTypes.Notes)
      field(:holder_name, Encryptor.Ecto.TestTypes.HolderName)
      field(:metadata, Encryptor.Ecto.TestTypes.Metadata)
    end
  end
end
