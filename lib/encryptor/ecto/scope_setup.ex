defmodule Encryptor.Ecto.ScopeSetup do
  @moduledoc """
  Sets the scope for an ExUnit case, or for one `describe` block.

  Fail-closed scoping shows up first in a host's test suite. Factories, seeds
  and setup blocks that never had to think about scopes start raising
  `Encryptor.Ecto.MissingScopeError` the moment a field becomes encrypted.
  That is the mechanism working (ADR-0001 decision 5c), and ADR-0001's
  Consequences commit this package to shipping the helper for it rather than
  leaving every host to write the same six lines.

  It lives in `lib/` rather than `test/` so that a host can call it, which is
  the same call the statifier family made for its own test helpers.

  ## Usage

      defmodule Payments.CardsTest do
        use ExUnit.Case, async: true
        import Encryptor.Ecto.ScopeSetup

        setup_scope "merchant_7f3"

        test "stores a card under the merchant in scope" do
          assert {:ok, _card} = Payments.Cards.store(%{pan: "4111111111111111"})
        end
      end

  Inside a `describe` block it scopes that block alone, so one case can cover
  two merchants without either leaking into the other:

      describe "the A variant of the signup wizard" do
        setup_scope "merchant_7f3"

        test "records the variant the applicant saw" do
          assert :ok = Signups.record_variant(:a)
        end
      end

  The paren-free form is the documented one, and this package exports it. A
  host adds one line to its `.formatter.exs` to keep the formatter from
  rewriting every call site:

      import_deps: [:ecto, :encryptor_ecto]

  ## It sets a scope; it never installs a default scope

  There is no zero-argument form, no configured fallback and no application
  environment key. Every call names its scope at the call site, on purpose: a
  helper that could supply one would turn decision 5c's fail-closed guarantee
  into something a host switches off in `test.exs` and then cannot tell is off
  in production. A scope that is not a non-empty binary is an `ArgumentError`
  rather than a silent substitution.

  A test that asserts the *absence* of a scope - that a dump with an empty
  scope raises - simply does not call this macro, or calls
  `Encryptor.Ecto.Scope.clear/0`.

  ## What it does not cover

  The scope is held per process (`Encryptor.Ecto.Scope`) and ExUnit runs each
  test in its own process, which fixes three things:

    * `setup_scope/1` expands to a `setup`, never a `setup_all`. A `setup_all`
      callback runs in a different process from the tests that follow it, so a
      scope put there would be set in none of them.
    * Cleanup is the test process exiting. Nothing leaks to the next test and
      `async: true` is safe.
    * Work a test spawns is a boundary like any other. A `Task`, a
      `Task.Supervisor` child, an Oban job run inline - each starts with an
      empty scope and wraps explicitly with `Encryptor.Ecto.Scope.wrap/2`.
      The full list of boundaries a host is expected to wrap is documented on
      `Encryptor.Ecto.Scope`.
  """

  alias Encryptor.Ecto.Scope

  @doc """
  Sets `scope` for every test in the enclosing case or `describe`
  block.

  Expands to an ExUnit `setup` callback, so it may be written anywhere `setup`
  may be: at the top of a case, or inside a `describe`. `scope` is any
  expression evaluating to a non-empty binary, evaluated once per test.

      setup_scope "merchant_7f3"
  """
  defmacro setup_scope(scope) do
    quote do
      setup do
        unquote(__MODULE__).put_scope(unquote(scope))
      end
    end
  end

  @doc """
  Sets `scope` for the calling process, refusing anything that is not
  a non-empty binary.

  This is the runtime half of `setup_scope/1`, and it is public because a host
  whose setup is already a function rather than a macro call wants the same
  refusal:

      setup context do
        Encryptor.Ecto.ScopeSetup.put_scope(context.merchant_id)
      end

  Returns `:ok`, which is also a valid ExUnit setup return.

      iex> Encryptor.Ecto.ScopeSetup.put_scope("merchant_7f3")
      :ok
      iex> Encryptor.Ecto.Scope.get()
      {:ok, "merchant_7f3"}
  """
  @spec put_scope(String.t()) :: :ok
  def put_scope(scope) when is_binary(scope) and byte_size(scope) > 0 do
    Scope.put(scope)
  end

  def put_scope(other) do
    raise ArgumentError,
          "expected a non-empty scope identifier, got: #{inspect(other)}. " <>
            "The test-support helper never substitutes a default scope; name " <>
            "the scope this case or describe block is scoped to at the call site."
  end
end
