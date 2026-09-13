defmodule Encryptor.Ecto.TestEnginePlans do
  @moduledoc """
  Plans the engine tests run, one per shape the engine has to handle.

  Kept apart from `Encryptor.Ecto.TestPlans`, which exists to exercise the
  DSL's compile-time checks: these are plans that *run*, against real rows in
  the test repository, and each one is here because the engine does something
  different with it.

  The legacy fields declare `source_authenticated: true` - the AEAD case
  ADR-0004 decision 3d calls the common one - so that the acknowledged shapes
  stand out: `Adoption`, `Unverified`, `Validated`, `RaisingValidator` and
  `Mixed`.
  """

  defmodule Cards do
    @moduledoc "The ordinary case: one encrypted column, tenant read off the row."

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.Pan,
        source_authenticated: true
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
        to: Encryptor.Ecto.TestTypes.Pan,
        source_authenticated: true

      field :notes,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.Notes,
        source_authenticated: true
    end
  end

  defmodule Racing do
    @moduledoc "The same rewrite through a type that lets a test write the row mid-dump."

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestEngineTypes.RacingPan,
        source_authenticated: true
    end
  end

  defmodule PlainTarget do
    @moduledoc "A plan whose `to:` is a plain `Ecto.Type` rather than one of ours."

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestEngineTypes.PlainTarget,
        source_authenticated: true
    end
  end

  defmodule DecliningTarget do
    @moduledoc "A plan whose `to:` refuses to write the value it is handed."

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestEngineTypes.DecliningTarget,
        source_authenticated: true
    end
  end

  defmodule Adoption do
    @moduledoc """
    The backfill leg of an adoption migration: a plaintext column read through
    `Source.Plaintext` and written `into:` the binary column the host's own
    DDL added (ADR-0002 decision 8).

    Plaintext authenticates nothing, so this plan is also the engine's
    `:migratable_unverified` fixture, and the `validate:` beside the
    acknowledgement is what lets it run in `--mode write` (ADR-0004 d3a).
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    alias Encryptor.Ecto.TestChecks

    rewrite Encryptor.Ecto.TestSchemas.Signup do
      tenant Encryptor.Ecto.TestResolvers.Fixed

      field :email,
        from: Encryptor.Ecto.Migrator.Source.Plaintext,
        to: Encryptor.Ecto.TestTypes.HolderName,
        into: :email_encrypted,
        source_authenticated: false,
        validate: &TestChecks.email?/1
    end
  end

  defmodule Global do
    @moduledoc "A global field: `tenant :none`, on the single-key vault."

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Signup do
      tenant :none

      field :variant_notes,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.GlobalName,
        source_authenticated: true
    end
  end

  defmodule Unverified do
    @moduledoc """
    An acknowledged-unauthenticated field with no `validate:` (ADR-0004
    decision 3a): its rows count `:migratable_unverified`, and `--mode write`
    is refused for it before a row is read.
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.Pan,
        source_authenticated: false
    end
  end

  defmodule Validated do
    @moduledoc """
    The same acknowledgement with the host's own check beside it: this one
    writes, and a row whose loaded value fails the check is `:undecryptable`
    (ADR-0004 decisions 3a and 3b).
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    alias Encryptor.Ecto.TestChecks

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.Pan,
        source_authenticated: false,
        validate: &TestChecks.pan?/1
    end
  end

  defmodule RaisingValidator do
    @moduledoc """
    A `validate:` that raises rather than answering. The pass reports the
    raising module and nothing else, exactly as it does for a legacy type that
    raises (ADR-0002 decision 11).
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    alias Encryptor.Ecto.TestChecks

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.Pan,
        source_authenticated: false,
        validate: &TestChecks.raises?/1
    end
  end

  defmodule OffContractValidator do
    @moduledoc """
    A `validate:` that answers with a truthy non-boolean. Decision 3b's
    contract is `(term() -> boolean())`, and the pass refuses the row rather
    than reading anything truthy as valid.
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    alias Encryptor.Ecto.TestChecks

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.Pan,
        source_authenticated: false,
        validate: &TestChecks.off_contract?/1
    end
  end

  defmodule Mixed do
    @moduledoc """
    One rewrite with an acknowledged field and an ordinary one, so that a
    report has to carry both migratable classes at once - and so that `only:`
    has something to narrow a refused write down to.
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.Pan,
        source_authenticated: false

      field :notes,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.Notes,
        source_authenticated: true
    end
  end

  defmodule SignedTarget do
    @moduledoc """
    A target whose vault writes the signing algorithm suite.

    The engine puts the signature's public key into the encryption context, so
    this plan is what proves the probe compares a declaration's own pairs
    rather than everything the header happens to carry.
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.PanSigned,
        source_authenticated: true
    end
  end

  defmodule Rekey do
    @moduledoc """
    A `from:` that is one of this package's own types: the same declared
    context under the re-keyed vault, rewritten into the ordinary one.

    This is the shape `Encryptor.Ecto.Migration` documents under "`from:` and
    `to:` may be the same module" and the one ADR-0004's 2026-08-28 amendment
    lets stay silent about `source_authenticated:` - the package that wrote
    the bytes authenticates them. Reading them needs the source type's *own*
    params, not the migrator's identifying map, which is the whole of what
    this plan is here to hold the engine to.
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestTypes.PanRekeyed,
        to: Encryptor.Ecto.TestTypes.Pan
    end
  end

  defmodule InPlaceEdit do
    @moduledoc """
    An in-place declaration edit, spelled the way ADR-0002 decision 3's
    2026-09-13 amendment says it is spelled: two declarations.

    `Encryptor.Ecto.TestTypes.Pan` is the declaration the bytes in the column
    were written under; `Encryptor.Ecto.TestTypes.Pinned` is the same column
    declared again with one more context pair, which is the edit. Naming
    `Pinned` on both sides could not describe those bytes - both sides would
    read the edited declaration - so the old declaration is kept as a module
    of its own and named `from:`.

    Like the re-key plan it needs no `source_authenticated:`: the `from:` type
    is one of this package's own.
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestTypes.Pan,
        to: Encryptor.Ecto.TestTypes.Pinned
    end
  end

  defmodule StaticContext do
    @moduledoc """
    A target whose vault writes a context pair no declaration composed.

    The other half of what the probe compares: `Encryptor.Ecto.Migrator`
    merges the vault's `:static_encryption_context` over the declared pairs
    once per pass, and this plan is the only thing in the suite that has a
    static pair to merge. A probe that dropped the merge would find its own
    rows unrecognisable.
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.PanStatic,
        source_authenticated: true
    end
  end

  defmodule LegacyWindow do
    @moduledoc """
    A target that declares `legacy:` - the mixed window, from the engine's
    side.

    ADR-0001's acceptance amendment 4 lets the target type read the prior
    scheme's bytes for as long as the window is open, which is exactly what
    makes the *load* probe the wrong question here: the target loads an
    un-migrated row successfully, and a probe that read success as "already in
    the target state" would count every remaining row migrated and rewrite
    none of them. The header probe cannot make that mistake - bytes that are
    not one of this package's messages carry no claim to compare - and this
    plan is where the difference is observable.

    `from:` is the same legacy reader the type names, because the two are the
    same host module doing the same job on either side of the window.
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestLegacy.Binary,
        to: Encryptor.Ecto.TestTypes.PanLegacy,
        source_authenticated: true
    end
  end

  defmodule Composite do
    @moduledoc "A rewrite of a composite-key schema, which the engine refuses to page."

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Composite do
      tenant_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.Pan,
        source_authenticated: true
    end
  end
end
