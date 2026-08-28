defmodule Encryptor.Ecto.RepoCase do
  @moduledoc """
  The case template every `:database`-tagged test uses.

  It tags the case `:database` itself, so a test file cannot pick up the
  repository and forget the tag that keeps it out of a developer's ordinary
  run - the failure mode being a suite that is green on a machine with
  Postgres and red on one without, for a reason the second machine's output
  does not explain.

  Checkout is a `SQL.Sandbox` connection per test, rolled back when the test
  process exits, which is what makes `async: true` safe here.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      @moduletag :database

      alias Encryptor.Ecto.TestRepo
    end
  end

  setup tags do
    pid =
      Sandbox.start_owner!(Encryptor.Ecto.TestRepo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
