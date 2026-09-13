defmodule Encryptor.Ecto.BlindIndex.GoldenVectorTest do
  @moduledoc """
  The end-to-end golden vector for a `slow: true` blind index: the bytes a
  host's index column actually stores, for one fixed plaintext, pinned as a
  literal.

  Every other assertion about a slow index recomputes its expected side
  through the same production functions the value under test went through -
  `Encryptor.Ecto.BlindIndex.Derivation.derive_salt/3`, the vault's frozen
  parameters, and `Encryptor.Kdf.slow_hash/3` itself. That makes them
  composition proofs, and composition proofs are blind to the one failure a
  stored index column cannot survive: a change *below* `slow_hash/3` - a
  different Argon2id parameter mapping in `argon2_elixir`, a different
  rounding in the KiB-to-exponent conversion, a different variant number -
  moves the bytes on both sides of the equality at once and the suite stays
  green while every already-written column silently stops matching.

  This vector is the one assertion in the suite that does not move with it.
  It is the package's determinism and stability proof for a slow index - a
  claim about which bytes get stored, not a second argument that the
  construction is the right one: the construction is argued in
  `Encryptor.Ecto.BlindIndex.ValueTest`, the HKDF halves are pinned in
  `Encryptor.Ecto.BlindIndex.DerivationTest`, and `slow_hash/3`'s own
  agreement with Argon2id belongs upstream to `encryptor` (enc-ADR-0003
  amendment B), which is why nothing here re-derives an Argon2id hash to
  compare against. What is claimed here is only that these inputs produce
  these bytes today and must keep producing them, because ece-ADR-0003
  amendment C decision C6 makes any change to them a column invalidation a
  host has to migrate through rather than a patch release.

  The literal was produced once, by running this package at main `0abb2db`
  with `encryptor` 0.3.0 and `argon2_elixir` 4.x, and is never recomputed from
  the code it pins. A failure here is therefore never fixed by re-running and
  pasting the new value: it is either a deliberate invalidation that C6 wants
  recorded, or a defect.
  """

  use ExUnit.Case, async: true

  alias Encryptor.Ecto.BlindIndex.Declaration
  alias Encryptor.Ecto.BlindIndex.Derivation
  alias Encryptor.Ecto.BlindIndex.Value
  alias Encryptor.Ecto.Tenant
  alias Encryptor.Ecto.TestSchemas.Customer
  alias Encryptor.Ecto.TestVaults

  # The fixed input. `Customer`'s phone index is the suite's only
  # `slow: true` declaration: `normalize: :digits`, `version: 2`,
  # `scope: :tenant` by default, 256 bits wide, on a vault that declares
  # `:slow_hash`.
  @tenant "merchant_7f3"
  @plaintext "+1 (555) 0100"

  # The parameter set the vector was computed under, restated as a literal so
  # that a change to the fixture vault's declaration fails *here*, naming
  # itself, rather than surfacing as an unexplained byte mismatch below.
  @params %{memory_kib: 32_768, iterations: 1, parallelism: 1}

  setup do
    Tenant.put(@tenant)
    on_exit(&Tenant.clear/0)
    :ok
  end

  describe "the stored slow index value (ece-ADR-0003 amendment C decision C6)" do
    # sabotage: `t_cost: iterations` -> `t_cost: iterations + 1` in the
    # dependency's own `Encryptor.Kdf.slow_hash/3` (deps/encryptor, recompiled
    # for :test) - red here and green everywhere else in the suite, which is
    # the whole reason this test exists.
    test "is these 32 pinned bytes: the determinism and stability proof" do
      declaration = Declaration.fetch!(Customer, :phone, :phone_index)

      assert Derivation.slow_params!(TestVaults.Merchant, Declaration.derivation!(declaration)) ==
               @params

      value = Value.compute!(declaration, @plaintext, :dump)

      assert byte_size(value) == 32

      assert Base.encode16(value, case: :lower) ==
               "83037c0bed24d41f8747e784a60abfde5d00dde4c8b3e3b1b8dae5ce5ef92be8"
    end
  end
end
