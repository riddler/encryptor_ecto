defmodule Encryptor.Ecto.TestEnginePlans do
  @moduledoc """
  Plans the engine tests run, one per shape the engine has to handle.

  Kept apart from `Encryptor.Ecto.TestPlans`, which exists to exercise the
  DSL's compile-time checks: these are plans that *run*, against real rows in
  the test repository, and each one is here because the engine does something
  different with it.
  """

  defmodule Cards do
    @moduledoc "The ordinary case: one encrypted column, tenant read off the row."

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.Pan
    end
  end

  defmodule BothColumns do
    @moduledoc """
    Two columns of one schema: two passes, two checkpoint rows, two cursors,
    and the subject of `only:`.
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.Pan

      field :notes,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.Notes
    end
  end

  defmodule Racing do
    @moduledoc "The same rewrite through a type that lets a test write the row mid-dump."

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestEngineTypes.RacingPan
    end
  end

  defmodule PlainTarget do
    @moduledoc "A plan whose `to:` is a plain `Ecto.Type` rather than one of ours."

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestEngineTypes.PlainTarget
    end
  end

  defmodule DecliningTarget do
    @moduledoc "A plan whose `to:` refuses to write the value it is handed."

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestEngineTypes.DecliningTarget
    end
  end

  defmodule Adoption do
    @moduledoc """
    The backfill leg of an adoption migration: a plaintext column read through
    `Source.Plaintext` and written `into:` the binary column the host's own
    DDL added (ADR-0002 decision 8).
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

  defmodule Global do
    @moduledoc "A global field: `tenant :none`, on the single-key vault."

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Signup do
      tenant :none

      field :variant_notes,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.GlobalName
    end
  end

  defmodule Composite do
    @moduledoc "A rewrite of a composite-key schema, which the engine refuses to page."

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Composite do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.Pan
    end
  end
end
