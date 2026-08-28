defmodule Encryptor.Ecto.BlindIndexHelpersTest do
  @moduledoc """
  ADR-0003 decisions 5, 8 and 9: the write helper, the two read helpers, and
  `compute/3`.

  Every arm here is answered from a schema, a declaration and a vault, with no
  database: the property decision 5 is built on is that the write side and the
  read side agree without one, and a test that needed a table to observe it
  would be testing Postgres instead.
  """

  use ExUnit.Case, async: true

  require Ecto.Query

  alias Ecto.Changeset
  alias Encryptor.Ecto.BlindIndex
  alias Encryptor.Ecto.BlindIndex.NormalizationError
  alias Encryptor.Ecto.MissingTenantError
  alias Encryptor.Ecto.Tenant
  alias Encryptor.Ecto.TestSchemas.Authorization
  alias Encryptor.Ecto.TestSchemas.Customer
  alias Encryptor.Ecto.TestSchemas.Identity
  alias Encryptor.Ecto.TestSchemas.SignupEmail
  alias Encryptor.Ecto.TestSchemas.Wizard

  @merchant "merchant_7f3"
  @other_merchant "merchant_a19"

  setup do
    on_exit(&Tenant.clear/0)
    :ok
  end

  # The one value every arm computes over, so a test that changes what is
  # stored is visibly changing the value rather than the plaintext.
  # `empty_values: []` because ADR-0003 decision 8 gives `""` a real index
  # value, and Ecto's default would drop the change before this package ever
  # saw it - which would make the empty-string arm assert Ecto's behaviour.
  defp phone_changeset(attrs, data \\ %Customer{}) do
    Changeset.cast(data, attrs, [:phone], empty_values: [])
  end

  defp pinned(query) do
    query.wheres |> hd() |> Map.fetch!(:params) |> Enum.map(&elem(&1, 0))
  end

  defp pinned_field(query) do
    query.wheres |> hd() |> Map.fetch!(:params) |> Enum.map(&elem(&1, 1))
  end

  describe "put_index/3 computes the column (decision 5)" do
    # sabotage: put_index/3's `{:ok, value}` arm putting `value` instead of the
    # computed HMAC, red - the plaintext lands in the index column, which is
    # both a wrong value and the leak the whole feature exists to prevent.
    test "a changed source is fingerprinted into the index column" do
      Tenant.put(@merchant)

      changeset =
        %{phone: "+1 (555) 0100"}
        |> phone_changeset()
        |> BlindIndex.put_index(:phone, :phone_index)

      assert {:ok, value} = Changeset.fetch_change(changeset, :phone_index)
      assert byte_size(value) == 32
      assert value == BlindIndex.compute(Customer, :phone, "+1 (555) 0100")
    end

    # sabotage: Value.compute!/3 taking the HMAC over `value` rather than
    # `normalized`, red - the two spellings stop agreeing and the index answers
    # byte equality instead of equality over `norm(plaintext)`.
    test "the declared normalizer is applied before the HMAC" do
      Tenant.put(@merchant)

      assert put_phone("+1 (555) 0100") == put_phone("1 555 0100")
    end

    # sabotage: `Changeset.fetch_change/2` -> `Changeset.fetch_field/2`, red -
    # an untouched source is recomputed, so an update that never cast the field
    # rewrites the column (and raises where no tenant is in scope).
    test "a source that was not changed is not recomputed" do
      Tenant.put(@merchant)

      changeset =
        %{}
        |> phone_changeset(%Customer{phone: "5550100"})
        |> BlindIndex.put_index(:phone, :phone_index)

      assert Changeset.fetch_change(changeset, :phone_index) == :error
    end

    # sabotage: the `{:ok, nil}` arm falling through to the compute arm, red -
    # normalizing nil raises instead of writing NULL.
    test "a source set to nil sets the index to nil (decision 8)" do
      Tenant.put(@merchant)

      changeset =
        %{phone: nil}
        |> phone_changeset(%Customer{phone: "5550100", phone_index: <<0, 1, 2>>})
        |> BlindIndex.put_index(:phone, :phone_index)

      assert Changeset.fetch_change(changeset, :phone_index) == {:ok, nil}
    end

    # sabotage: the `{:ok, nil}` arm moved below the compute arm, red - writing
    # NULL starts requiring a tenant it does not need.
    test "writing nil needs no tenant, because it derives no key" do
      changeset =
        %{phone: nil}
        |> phone_changeset(%Customer{phone: "5550100", phone_index: <<0, 1, 2>>})
        |> BlindIndex.put_index(:phone, :phone_index)

      assert Changeset.fetch_change(changeset, :phone_index) == {:ok, nil}
    end

    # sabotage: Normalizer.normalize!/3's `:digits` arm returning `nil` for an
    # empty result, red - the empty string stops producing a value.
    test "an empty source produces a real value over norm(\"\") (decision 8)" do
      Tenant.put(@merchant)

      assert byte_size(put_phone("")) == 32
    end

    # sabotage: Declaration.derivation!/1 dropping `index_name`, red - two
    # indexes over one field collapse onto one key and one value.
    test "two indexes over one field are written independently" do
      Tenant.put(@merchant)

      changeset =
        %Authorization{}
        |> Changeset.cast(%{card_number: "4111 1111 1111 1111"}, [:card_number])
        |> BlindIndex.put_index(:card_number, :card_number_index)
        |> BlindIndex.put_index(:card_number, :card_number_v2_index)

      assert {:ok, v1} = Changeset.fetch_change(changeset, :card_number_index)
      assert {:ok, v2} = Changeset.fetch_change(changeset, :card_number_v2_index)
      assert byte_size(v1) == 32
      refute v1 == v2
    end

    # sabotage: Derivation.selector!/3's `:global` clause resolving through the
    # tenant strategy, red - a global index starts demanding a tenant.
    test "a scope: :global index needs no tenant" do
      changeset =
        %Identity{}
        |> Changeset.cast(%{email: "bob@example.com"}, [:email])
        |> BlindIndex.put_index(:email, :email_index)

      assert {:ok, value} = Changeset.fetch_change(changeset, :email_index)
      assert byte_size(value) == 32
    end
  end

  describe "put_index/3 refuses what it cannot compute" do
    # sabotage: Value.compute!/3 resolving the selector after normalizing, red
    # only for the ordering arm below; this one stays green either way and is
    # here because a write outside scope must raise at all.
    test "a scope: :tenant index outside tenant scope raises" do
      assert_raise MissingTenantError, fn ->
        %{phone: "5550100"}
        |> phone_changeset()
        |> BlindIndex.put_index(:phone, :phone_index)
      end
    end

    # sabotage: put_index/3 calling Declaration.fetch/3 and ignoring `:error`,
    # red - a misspelled column silently writes nothing.
    test "an undeclared {source, column} pair raises, naming what is declared" do
      assert_raise ArgumentError, ~r/declares no blind index on :phone/, fn ->
        %{phone: "5550100"}
        |> phone_changeset()
        |> BlindIndex.put_index(:phone, :nowhere)
      end
    end

    # sabotage: changeset_schema!/1's fallback clause returning `nil`, red -
    # the failure arrives as an UndefinedFunctionError on nil.__schema__/2.
    test "a changeset over a bare map raises, naming the reason" do
      changeset = Changeset.cast({%{}, %{phone: :string}}, %{phone: "5550100"}, [:phone])

      assert_raise ArgumentError, ~r/needs a changeset over a schema struct/, fn ->
        BlindIndex.put_index(changeset, :phone, :phone_index)
      end
    end
  end

  describe "where_eq/3 constrains the index column (decisions 5 and 9)" do
    # sabotage: equality/3 pinning `declaration.source` instead of
    # `declaration.column`, red - the query constrains the ciphertext column.
    test "the constraint names the index column, pinned to the computed value" do
      Tenant.put(@merchant)

      query = BlindIndex.where_eq(Customer, :phone, "+1 (555) 0100")

      assert pinned_field(query) == [{0, :phone_index}]
      assert pinned(query) == [BlindIndex.compute(Customer, :phone, "+1 (555) 0100")]
    end

    # sabotage: Value.compute!/3's `operation` hardcoded to `:dump`, red only
    # for a resolver that answers differently; this arm asserts the pairing the
    # two helpers must have, which no mutation of one side alone survives.
    test "the write side and the read side agree on the bytes" do
      Tenant.put(@merchant)

      written = put_phone("+1 (555) 0100")

      assert pinned(BlindIndex.where_eq(Customer, :phone, "1-555-0100")) == [written]
    end

    # sabotage: the normalizer skipped on the read side, red - a query built
    # from the spelling a host has finds nothing the write side stored.
    test "the value is normalized before it is fingerprinted" do
      Tenant.put(@merchant)

      assert pinned(BlindIndex.where_eq(Customer, :phone, "+1 (555) 0100")) ==
               pinned(BlindIndex.where_eq(Customer, :phone, "1-555-0100"))
    end

    # sabotage: Derivation.derive_opts/2's `key:` option dropped, red - every
    # tenant derives under the vault's default key and the index becomes
    # cross-tenant correlatable, which is decision 3b's whole argument.
    test "two tenants pin different constants for one plaintext" do
      Tenant.put(@merchant)
      first = pinned(BlindIndex.where_eq(Customer, :phone, "5550100"))

      Tenant.put(@other_merchant)
      second = pinned(BlindIndex.where_eq(Customer, :phone, "5550100"))

      refute first == second
    end

    # sabotage: equality/3 pinning `declaration.source` rather than
    # `declaration.column`, red - and red here specifically because a joined
    # query is where a wrong binding would first constrain somebody else's
    # table rather than the schema the declaration was read from.
    test "the constraint binds the query's own source, not a joined one" do
      Tenant.put(@merchant)

      query =
        Customer
        |> Ecto.Query.join(:inner, [c], i in Identity, on: true)
        |> BlindIndex.where_eq(:phone, "5550100")

      assert pinned_field(query) == [{0, :phone_index}]
    end

    # sabotage: where_eq/3 dropping the `Ecto.Query.where/3` call and returning
    # the query, red - the helper builds an unconstrained query, which is the
    # "matches everything" mirror of the failure decision 5 names.
    test "the constraint is added to an existing query" do
      Tenant.put(@merchant)

      query =
        Customer
        |> Ecto.Query.where([c], c.merchant_id == "acct_a")
        |> BlindIndex.where_eq(:phone, "5550100")

      assert length(query.wheres) == 2
    end
  end

  describe "where_eq/3 raises rather than matching nothing" do
    # sabotage: Derivation.selector!/3's `{:error, reason}` arm returning
    # `{:tenant, ""}`, red - a query built outside scope is executable and
    # matches nothing, which decision 5 calls the worst failure this feature
    # can have because it reads as "the record does not exist".
    test "a query built outside tenant scope raises at build time" do
      assert_raise MissingTenantError, fn ->
        BlindIndex.where_eq(Customer, :phone, "5550100")
      end
    end

    # sabotage: refuse_truncated!/1 accepting every width, red - a truncated
    # index answers through the helper that promises matches, and the caller
    # never learns it has to filter after decrypting.
    test "a truncated index is refused by name (decision 6)" do
      Tenant.put(@merchant)

      assert_raise ArgumentError, ~r/where_eq_candidates\/3/, fn ->
        BlindIndex.where_eq(Customer, :email, :email_short_index, "bob@example.com")
      end
    end

    # sabotage: sole_declaration!/4's multi-declaration clause returning
    # `hd(declarations)`, red - the helper silently picks one of two keys, so
    # half the rotation window queries the wrong column.
    test "a field carrying two indexes is refused, naming the four-argument form" do
      Tenant.put(@merchant)

      assert_raise ArgumentError, ~r/where_eq\/4/, fn ->
        BlindIndex.where_eq(Authorization, :card_number, "4111111111111111")
      end
    end

    # sabotage: sole_declaration!/4's `[]` clause returning a new Declaration,
    # red - a source with no index builds a query over a column nobody wrote.
    test "a field carrying no index is refused" do
      Tenant.put(@merchant)

      assert_raise ArgumentError, ~r/declares no blind index on :merchant_id/, fn ->
        BlindIndex.where_eq(Customer, :merchant_id, "acct_a")
      end
    end

    # sabotage: query_schema!/1's fallback returning the table binary, red -
    # the failure becomes an UndefinedFunctionError on "customers".__schema__/2.
    test "a query over a table name rather than a schema is refused" do
      Tenant.put(@merchant)

      assert_raise ArgumentError, ~r/needs a queryable over a schema module/, fn ->
        BlindIndex.where_eq(Ecto.Query.from(c in "customers"), :phone, "5550100")
      end
    end
  end

  describe "where_eq/4 and where_eq_candidates" do
    # sabotage: where_eq/4 resolving through sole_declaration!/4 rather than
    # fetch!/3, red - naming the column stops being able to disambiguate, and
    # decision 7 step 4 has no expression.
    test "where_eq/4 names one index of a rotation pair" do
      Tenant.put(@merchant)

      v1 = BlindIndex.where_eq(Authorization, :card_number, :card_number_index, "4111")
      v2 = BlindIndex.where_eq(Authorization, :card_number, :card_number_v2_index, "4111")

      assert pinned_field(v1) == [{0, :card_number_index}]
      assert pinned_field(v2) == [{0, :card_number_v2_index}]
      refute pinned(v1) == pinned(v2)
    end

    # sabotage: where_eq_candidates/4 calling refuse_truncated!/1, red - the
    # helper named for truncated indexes refuses the only indexes it is for.
    test "where_eq_candidates accepts a truncated index" do
      Tenant.put(@merchant)

      query = BlindIndex.where_eq_candidates(Customer, :email, :email_short_index, "bob@x.com")

      assert pinned_field(query) == [{0, :email_short_index}]
    end

    # sabotage: where_eq_candidates/3 delegating to where_eq/3, red - the
    # helper named for truncated indexes refuses them at the arity a host
    # writes, and the only surface that answers a truncated index is the one
    # that names the column.
    test "where_eq_candidates/3 resolves a truncated index by source alone" do
      Tenant.put(@merchant)

      query = BlindIndex.where_eq_candidates(Wizard, :email, "bob@example.com")

      assert pinned_field(query) == [{0, :email_index}]
    end

    # sabotage: refuse_truncated!/1 accepting every width, red - the arity a
    # host writes stops steering a truncated index to the candidates helper.
    test "where_eq/3 refuses a truncated index at the same arity" do
      Tenant.put(@merchant)

      assert_raise ArgumentError, ~r/where_eq_candidates\/3/, fn ->
        BlindIndex.where_eq(Wizard, :email, "bob@example.com")
      end
    end

    # sabotage: where_eq_candidates/3 delegating to where_eq/3, red - the
    # weaker contract stops being available over a full-width index.
    test "where_eq_candidates accepts a full-width index" do
      Tenant.put(@merchant)

      assert pinned(BlindIndex.where_eq_candidates(Customer, :phone, "5550100")) ==
               pinned(BlindIndex.where_eq(Customer, :phone, "5550100"))
    end

    # sabotage: where_eq_candidates/3 resolving the schema before checking the
    # tenant - it cannot; this asserts the raise reaches the candidates helper
    # at all, which a delegation that skipped selector!/3 would lose.
    test "where_eq_candidates raises outside tenant scope too" do
      assert_raise MissingTenantError, fn ->
        BlindIndex.where_eq_candidates(Customer, :phone, "5550100")
      end
    end
  end

  describe "compute/3 and compute/4" do
    # sabotage: compute/3's `:load` -> `:dump`, green here and red in
    # `Encryptor.Ecto.BlindIndex.ValueTest`'s operation arm, which is where the
    # two are told apart; this arm pins the width and the agreement.
    test "compute/3 returns the 32 bytes where_eq pins" do
      Tenant.put(@merchant)

      value = BlindIndex.compute(Customer, :phone, "5550100")

      assert byte_size(value) == 32
      assert pinned(BlindIndex.where_eq(Customer, :phone, "5550100")) == [value]
    end

    # sabotage: Declaration.derivation!/1 reading `declaration.source` for the
    # info string's column, red - two indexes over one field derive one key.
    test "compute/4 derives a different value per index name" do
      Tenant.put(@merchant)

      refute BlindIndex.compute(Authorization, :card_number, :card_number_index, "4111") ==
               BlindIndex.compute(Authorization, :card_number, :card_number_v2_index, "4111")
    end

    # sabotage: sole_declaration!/4's ambiguity clause dropped, red - compute/3
    # picks a key for the caller.
    test "compute/3 refuses an ambiguous field, naming compute/4" do
      Tenant.put(@merchant)

      assert_raise ArgumentError, ~r/compute\/4/, fn ->
        BlindIndex.compute(Authorization, :card_number, "4111")
      end
    end

    # sabotage: Value.compute!/3 skipping selector!/3 for a `scope: :global`
    # declaration's sibling - i.e. resolving the selector last, red: the
    # normalizer's refusal arrives before the missing tenant does, and the host
    # is told about their value rather than about their scope.
    test "the scope check precedes normalization" do
      assert_raise MissingTenantError, fn ->
        BlindIndex.compute(Customer, :phone, :not_a_binary)
      end
    end

    # sabotage: Normalizer.normalize!/3's non-binary clause returning `""`,
    # red - a value this package cannot fingerprint is silently indexed as the
    # empty string, so every such row collides.
    test "a value that is not a binary is the normalizer's refusal" do
      Tenant.put(@merchant)

      assert_raise NormalizationError, fn ->
        BlindIndex.compute(Customer, :phone, :not_a_binary)
      end
    end
  end

  describe "the failures stay in the right words" do
    # sabotage: Value.compute!/3 wrapping the vault's error in a
    # DerivationError, red - a deployment's missing :derivation_salt is
    # reported as a fault in the index declaration, sending the reader to the
    # wrong file.
    test "a vault that cannot derive is reported in the vault's own words" do
      assert_raise Encryptor.Error, fn ->
        BlindIndex.compute(SignupEmail, :email, "bob@example.com")
      end
    end

    # sabotage: DerivationError/NormalizationError message assembly putting the
    # value in - these are the family's own tests elsewhere; this arm holds the
    # line at the surface the host actually calls.
    test "no failure message carries the plaintext or the index value" do
      Tenant.put(@merchant)

      plaintext = "5550100"
      value = BlindIndex.compute(Customer, :phone, plaintext)

      error =
        assert_raise(ArgumentError, fn ->
          BlindIndex.where_eq(Customer, :email, :email_short_index, plaintext)
        end)

      message = Exception.message(error)

      refute String.contains?(message, plaintext)
      refute String.contains?(message, Base.encode16(value))
    end
  end

  defp put_phone(value) do
    changeset =
      %{phone: value}
      |> phone_changeset()
      |> BlindIndex.put_index(:phone, :phone_index)

    {:ok, computed} = Changeset.fetch_change(changeset, :phone_index)
    computed
  end
end
