defmodule Encryptor.Ecto.KeyStoreConformanceTest do
  @moduledoc """
  `Encryptor.Ecto.KeyStore` held to `encryptor`'s shared provider suite.

  The suite ships in the vault's `lib/` precisely so that an adapter in
  another package runs the same properties its own adapters run: the
  candidate-list ordering, the head rule, distinct names, stability, the
  keyring the list builds, and the settled `:unknown_key`. Running it here is
  the bead's acceptance criterion, and the value of it is that none of those
  properties are restated in this repository where they could drift.

  It is `use`d directly rather than through `Encryptor.Ecto.RepoCase`, because
  the suite brings its own `ExUnit.Case`. The two things the case template
  would have supplied - the `:database` tag and a sandbox checkout - are
  therefore spelled here.

  The case provisions one scope with a single version and one with two, so
  the suite's "a bare `RawAes` from one candidate and a `Multi` from more"
  property has both arms to check rather than trivially passing on one.
  """

  use Encryptor.Provider.Conformance, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Encryptor.Ecto.KeyStore
  alias Encryptor.Ecto.TestKeyStore
  alias Encryptor.Ecto.TestRepo

  @moduletag :database

  setup do
    pid = Sandbox.start_owner!(TestRepo, shared: false)
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    TestKeyStore.provision!("merchant_7f3", 1)
    TestKeyStore.provision!("merchant_a19", 1)
    TestKeyStore.provision!("merchant_a19", 2)

    :ok
  end

  @impl Encryptor.Provider.Conformance
  def provider_case do
    %{
      provider: KeyStore,
      opts: TestKeyStore.provider_opts(),
      selectors: ["merchant_7f3", "merchant_a19"],
      unknown: ["merchant_none"]
    }
  end
end
