defmodule Encryptor.Ecto.TestSchemas.Customer do
  @moduledoc """
  ADR-0003's worked example, as a schema the doctests and the declaration
  tests read.

  Two indexes over one field - a full one and a narrow one - are what makes
  the `index_name` default observable: they are distinct because their index
  columns are, without either declaration writing a `:name`.

  No table backs it. Everything asserted about a declaration is answered from
  the schema and the encrypted field's frozen params, which is the property
  that lets the write side and the read side agree without a database.
  """

  use Ecto.Schema

  import Encryptor.Ecto.BlindIndex

  alias Encryptor.Ecto.TestTypes

  @type t :: %__MODULE__{}

  schema "customers" do
    field(:merchant_id, :string)

    field(:email, TestTypes.HolderName)
    field(:email_index, :binary)
    blind_index(:email, :email_index, normalize: :email)

    field(:email_short_index, :binary)
    blind_index(:email, :email_short_index, normalize: :email, bits: 64)

    field(:phone, TestTypes.HolderName)
    field(:phone_index, :binary)
    blind_index(:phone, :phone_index, normalize: :digits, slow: true, version: 2)
  end
end

defmodule Encryptor.Ecto.TestSchemas.Identity do
  @moduledoc """
  The cross-tenant login path of ADR-0003's worked example: a `tenant: :none`
  field whose index writes `scope: :global` out loud, because decision 3c
  makes silence there an error.
  """

  use Ecto.Schema

  import Encryptor.Ecto.BlindIndex

  alias Encryptor.Ecto.TestTypes

  @type t :: %__MODULE__{}

  schema "identities" do
    field(:email, TestTypes.GlobalName)
    field(:email_index, :binary)
    blind_index(:email, :email_index, scope: :global, normalize: :email)
  end
end

defmodule Encryptor.Ecto.TestSchemas.Authorization do
  @moduledoc """
  Decision 7's rotation window, as a schema: two full-width indexes over one
  field, distinguished only by their `:version` and their columns.

  This is the shape `where_eq/3` cannot resolve and `where_eq/4` exists for -
  during the window both versions are declared, both are written, and the
  source field names neither.
  """

  use Ecto.Schema

  import Encryptor.Ecto.BlindIndex

  alias Encryptor.Ecto.TestTypes

  @type t :: %__MODULE__{}

  schema "authorizations" do
    field(:merchant_id, :string)

    field(:card_number, TestTypes.HolderName)
    field(:card_number_index, :binary)
    field(:card_number_v2_index, :binary)

    blind_index(:card_number, :card_number_index, normalize: :digits)
    blind_index(:card_number, :card_number_v2_index, normalize: :digits, version: 2)
  end
end

defmodule Encryptor.Ecto.TestSchemas.SignupEmail do
  @moduledoc """
  A signup wizard's email, indexed on the vault that refuses to derive.

  Everything up to the derivation succeeds here, which is what makes the
  "a vault error is reported in the vault's words" arm observable.
  """

  use Ecto.Schema

  import Encryptor.Ecto.BlindIndex

  alias Encryptor.Ecto.TestTypes

  @type t :: %__MODULE__{}

  schema "signups" do
    field(:email, TestTypes.UnsaltedName)
    field(:email_index, :binary)

    blind_index(:email, :email_index, scope: :global, normalize: :email)
  end
end

defmodule Encryptor.Ecto.TestSchemas.Wizard do
  @moduledoc """
  A signup wizard's email under a single, truncated index.

  One index on the field, so the three-argument helpers resolve it - which is
  what makes `where_eq/3`'s refusal and `where_eq_candidates/3`'s acceptance
  observable at the arity a host actually writes.
  """

  use Ecto.Schema

  import Encryptor.Ecto.BlindIndex

  alias Encryptor.Ecto.TestTypes

  @type t :: %__MODULE__{}

  schema "wizards" do
    field(:email, TestTypes.HolderName)
    field(:email_index, :binary)

    blind_index(:email, :email_index, normalize: :email, bits: 64)
  end
end

defmodule Encryptor.Ecto.TestSchemas.Capture do
  @moduledoc """
  A field whose tenant resolver answers differently for a write than for a
  read, so that which `Encryptor.Ecto.TenantContext` operation an index
  computation asks with is observable in the bytes.
  """

  use Ecto.Schema

  import Encryptor.Ecto.BlindIndex

  alias Encryptor.Ecto.TestTypes

  @type t :: %__MODULE__{}

  schema "captures" do
    field(:reference, TestTypes.PerOperationName)
    field(:reference_index, :binary)

    blind_index(:reference, :reference_index, normalize: :trim)
  end
end

defmodule Encryptor.Ecto.TestNormalizers do
  @moduledoc "Host normalizers, one per way a `{module, function}` can behave."

  @doc "The well-behaved case: E.164-ish, which is what `:digits` cannot be."
  @spec e164(binary()) :: binary()
  def e164(value), do: "+" <> for(<<byte <- value>>, byte in ?0..?9, into: "", do: <<byte>>)

  @doc "Raises, with the value in its message - the leak the rescue must not copy."
  @spec raising(binary()) :: no_return()
  def raising(value), do: raise(ArgumentError, "cannot normalize #{value}")

  @doc "Throws rather than raising."
  @spec throwing(binary()) :: no_return()
  def throwing(value), do: throw(value)

  @doc "Exits rather than raising."
  @spec exiting(binary()) :: no_return()
  def exiting(value), do: exit(value)

  @doc "Returns something that is not a binary."
  @spec charlist(binary()) :: charlist()
  def charlist(value), do: String.to_charlist(value)
end
