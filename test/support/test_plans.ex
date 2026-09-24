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
    with the scope read off the row - and a second schema after it, because
    the order a plan declares its rewrites in is the order the pass runs and
    the report prints them.

    Every field declares `source_authenticated: true`, which is what ADR-0004's
    2026-08-28 amendment asks of a `from:` this package cannot prove
    authenticates: the plan asserts that someone checked the legacy cipher.
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      scope_from :merchant_id

      field :pan,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.Pan,
        source_authenticated: true

      field :notes,
        from: Encryptor.Ecto.TestSources.LegacyParameterizedType,
        to: Encryptor.Ecto.TestTypes.Notes,
        source_authenticated: true
    end

    rewrite Encryptor.Ecto.TestSchemas.Signup do
      scope :none

      field :email_encrypted,
        from: Encryptor.Ecto.TestSources.LegacyType,
        to: Encryptor.Ecto.TestTypes.HolderName,
        source_authenticated: true
    end
  end

  defmodule SameModuleBothSides do
    @moduledoc """
    The same module on both sides, which the plan format accepts (ADR-0002
    decision 3): a rewrite may name one of this package's own types on either
    side, and this fixture is what pins the compiler's acceptance of the
    spelling. The 2026-09-13 amendment withdrew the claim that this spelling
    expresses an in-place declaration edit - that is two declarations - and
    left the spelling itself accepted.

    It is also the one shape that needs no `source_authenticated:`: the `from:`
    type is one of this package's own, so the amendment's silence is earned
    rather than assumed.
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    rewrite Encryptor.Ecto.TestSchemas.Card do
      scope :none

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
    the scope.

    Plaintext authenticates nothing, so the acknowledgement is `false` and a
    `validate:` comes with it - which is also what lets this plan run in
    `--mode write` at all (ADR-0004 decision 3a).
    """

    use Encryptor.Ecto.Migration, repo: Encryptor.Ecto.TestRepo

    alias Encryptor.Ecto.TestChecks

    rewrite Encryptor.Ecto.TestSchemas.Signup do
      scope Encryptor.Ecto.TestResolvers.Fixed

      field :email,
        from: Encryptor.Ecto.Migrator.Source.Plaintext,
        to: Encryptor.Ecto.TestTypes.HolderName,
        into: :email_encrypted,
        source_authenticated: false,
        validate: &TestChecks.email?/1
    end
  end
end
