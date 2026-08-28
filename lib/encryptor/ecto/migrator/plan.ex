defmodule Encryptor.Ecto.Migrator.Plan do
  @moduledoc """
  What a migration plan module compiles to.

  A plan is a value: one repo and a list of rewrites, each naming a schema,
  how the tenant is resolved for its rows, and the fields to rewrite. The
  macros in `Encryptor.Ecto.Migration` build it at compile time and a plan
  module hands it over through `c:Encryptor.Ecto.Migration.__plan__/0`; the
  migrator (`ece-b25`) reads it and nothing else.

  Keeping the compiled form a plain struct rather than generated behaviour
  callbacks is what makes a plan inspectable. `MyApp.CloakMigration.__plan__()`
  in a console prints the whole thing, a test can assert against it without
  running a pass, and the dry-run report has something to name its rows after.

  ## What the tenant field means here

  ADR-0002 decision 3: the migrator supplies the tenant explicitly, per row,
  rather than reading an ambient scope. So a rewrite's `:tenant` says where
  the *migrator* finds it:

    * `{:column, :account_id}` - read it off the row being rewritten, which is
      `tenant_from :account_id` in the DSL.
    * `:none` - the field is global; there is no tenant to resolve.
    * a module - an `Encryptor.Ecto.TenantContext` implementation the migrator
      asks, for a host whose tenant is not a column of the table being
      rewritten.

  `:scope` is deliberately absent, and the DSL refuses it: process scope is
  ambient state a migrator running from a release command does not have, and
  a plan that silently read the empty scope would rewrite every row under the
  wrong key.
  """

  alias Encryptor.Ecto.Migration

  @typedoc """
  How the migrator resolves the tenant for the rows of one rewrite.

  See the moduledoc for why `:scope` is not one of them.
  """
  @type tenant :: {:column, atom()} | :none | module()

  @typedoc """
  One schema's rewrite: its tenant strategy and its fields, in declared order.

  Each field is `{name, field_spec}`, where the name is the schema field the
  bytes are read from and the spec is `t:Encryptor.Ecto.Migration.field_spec/0`.
  """
  @type rewrite :: %{
          schema: module(),
          tenant: tenant(),
          fields: [{atom(), Migration.field_spec()}]
        }

  @typedoc "A compiled plan: one repo (ADR-0002 decision 12) and its rewrites."
  @type t :: %__MODULE__{repo: module(), rewrites: [rewrite()]}

  @enforce_keys [:repo, :rewrites]
  defstruct [:repo, :rewrites]
end
