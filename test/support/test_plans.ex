defmodule Encryptor.Ecto.TestPlans do
  @moduledoc """
  Plan modules the `Encryptor.Ecto.Migration` tests read.

  A plan that compiles is the interesting half of the fixture: these modules
  are compiled by the ordinary compiler along with the rest of `test/support`,
  so every check in the DSL has already run against them before a test asserts
  anything. The failing plans are compiled from strings inside the tests
  instead - a fixture file that refuses to compile takes the suite with it.
  """

  defmodule Cloak do
    @moduledoc """
    The record's own example, in miniature: two encrypted columns of one
    schema, rewritten from a legacy `Ecto.Type` into the host's new types,
    with the tenant read off the row - and a second schema after it, because
    the order a plan declares its rewrites in is the order the pass runs and
    the report prints them.
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.Pan

      field :notes,
        from: Encryptor.Ecto.TestSources.LegacyParameterizedType,
        to: Encryptor.Ecto.TestTypes.Notes
    end

    rewrite Encryptor.Ecto.TestSchemas.Signup do
      tenant :none

      field :email_encrypted,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.HolderName
    end
  end

  defmodule ContextChange do
    @moduledoc """
    The same module on both sides (ADR-0002 decision 3): nothing about the
    type changed, the declared context did, and that is a full rewrite the
    plan format has to be able to say.
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant :none

      field :pan,
        from: Encryptor.Ecto.TestTypes.Pan,
        to: Encryptor.Ecto.TestTypes.Pan
    end
  end

  defmodule Adoption do
    @moduledoc """
    The backfill leg of an adoption migration (ADR-0002 decision 8): a
    plaintext column read through `Source.Plaintext` and written `into:` the
    binary column the host's own DDL added, with a resolver module supplying
    the tenant.
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Signup do
      tenant Encryptor.Ecto.TestResolvers.Fixed

      field :email,
        from: Encryptor.Ecto.Migrator.Source.Plaintext,
        to: Encryptor.Ecto.TestTypes.HolderName,
        into: :email_encrypted
    end
  end
end
