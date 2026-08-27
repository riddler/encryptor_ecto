defmodule Encryptor.Ecto.TenantContext do
  @moduledoc """
  Resolves the tenant identifier for an encrypted field.

  An encrypted field declares *how* its tenant is resolved, not *what* the
  tenant is: `tenant: :scope` reads the current process scope, `tenant: :none`
  declares the field global, and `tenant: MyApp.SomeResolver` names a module
  implementing this behaviour (ADR-0001 decision 5f).

  The behaviour is one callback. `c:resolve/2` is handed the operation being
  performed and the declared context of the field it is being performed on,
  and answers with the tenant identifier, `:none`, or an error:

    * `{:ok, tenant}` - encrypt or decrypt under this tenant's key.
    * `:none` - this value has no tenant. A global field, deliberately: its
      ciphertext is not crypto-shreddable with a tenant key.
    * `{:error, reason}` - the tenant could not be resolved. The caller raises;
      it never falls back to a default tenant, because a row written under the
      wrong key is unrecoverable in a way an exception is not (ADR-0001
      decision 5c).

  ## The default strategy is not privileged

  `Encryptor.Ecto.TenantContext.Scope` - the implementation behind
  `tenant: :scope` - is an ordinary implementation of this behaviour with no
  access the callback does not give a host's own module. A host that already
  has an ambient request context can substitute its own resolver by changing
  the `:tenant` option and nothing else.

  ## Example

  A payment host that has already resolved the merchant onto a Plug-assigned
  struct, and would rather read it there than mirror it into a second place:

      defmodule Payments.MerchantResolver do
        @behaviour Encryptor.Ecto.TenantContext

        @impl Encryptor.Ecto.TenantContext
        def resolve(_operation, _params) do
          case Payments.RequestContext.current() do
            %{merchant_id: id} when is_binary(id) -> {:ok, id}
            _other -> {:error, :no_request_context}
          end
        end
      end

  Declared at the field's type module:

      defmodule Payments.Encrypted.Binary do
        use Encryptor.Ecto.Binary,
          vault: Payments.Vault,
          tenant: Payments.MerchantResolver
      end

  `operation` is passed because a resolver may legitimately answer differently
  for a write and a read - a host reading historical rows through a background
  reporting job has a `:load` tenant it does not have on `:dump`.
  """

  @typedoc "The operation the type is performing when it asks."
  @type operation :: :dump | :load

  @typedoc """
  The declared context of the field being dumped or loaded.

  `:table` and `:column` are the field's *declared* context values, frozen at
  declaration time (ADR-0001 acceptance amendment 5), not necessarily the
  physical names in use today. `:opts` carries the field's remaining declared
  options for a resolver that wants them.
  """
  @type params :: %{
          required(:vault) => module(),
          required(:table) => String.t(),
          required(:column) => String.t(),
          optional(:opts) => keyword()
        }

  @doc """
  Resolves the tenant identifier for one dump or load.

  Returning `{:error, reason}` fails the operation loudly. A resolver must not
  substitute a default tenant for one it could not resolve.
  """
  @callback resolve(operation(), params()) ::
              {:ok, String.t()} | :none | {:error, term()}
end
