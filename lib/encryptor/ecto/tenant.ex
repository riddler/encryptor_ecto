defmodule Encryptor.Ecto.Tenant do
  @moduledoc """
  The current tenant, scoped to the calling process.

  This is a thin, documented wrapper over the process dictionary - the same
  mechanism `Logger.metadata/1` and `Ecto.Repo`'s dynamic repo use, chosen for
  the same reason. `Ecto.Type` callbacks run in the caller's process and
  receive the value and the type params, never the parent struct, so a
  process-scoped store is the only channel that reaches them without threading
  a parameter through every intervening signature (ADR-0001 decision 5a).

  The host sets the scope explicitly at the edge of a unit of work:

      Encryptor.Ecto.Tenant.put("merchant_7f3")

  ## Scope does not propagate

  It does not, and this package does not pretend it does. A `Task`, a
  `Task.Supervisor` child, an Oban worker, a `GenServer` doing the write on
  someone else's behalf - each starts with an empty scope. The host propagates
  explicitly (ADR-0001 decision 5b):

      tenant = Encryptor.Ecto.Tenant.fetch!()
      Task.async(fn -> Encryptor.Ecto.Tenant.wrap(tenant, &settle_batch/0) end)

  Making this visible is the point: an invisible propagation mechanism is one
  whose gaps are also invisible. The boundaries a host is expected to wrap are
  every place a unit of work starts - a Plug pipeline, a job's `perform/1`, a
  channel `join/3`, a test case's setup, a `Task` a request spawns.

  ## Prefer `wrap/2` in a pooled process

  A process that is checked out, used, and returned - a `Phoenix.Channel`
  process, a pooled worker, an `ExUnit` test process running several cases -
  must not leak its scope to the next unit of work. `wrap/2` restores whatever
  was in scope before it rather than clearing, so nesting one unit of work
  inside another is safe:

      Encryptor.Ecto.Tenant.wrap("merchant_7f3", fn ->
        # ... one signup wizard variant's writes, scoped to this merchant
      end)

  `put/1` without a matching `clear/0` or `wrap/2` is the failure mode this
  module names loudest, because its symptom appears in the *next* unit of work
  rather than in the one with the bug.

  ## What this module does not do

  It does not decide whether a field is tenant-scoped, and it does not raise
  `Encryptor.Ecto.MissingTenantError`. A field declares its strategy at its
  type module, and the raise for a dump or load with no tenant in scope belongs
  to the type's `dump/3` and `load/3`, which know the table and column to name.
  This module only holds and hands back a string.
  """

  @dict_key :"$encryptor_ecto_tenant"

  @doc """
  Puts `tenant` in scope for the calling process.

  Returns `:ok`. Any tenant already in scope is replaced; the previous value is
  not returned, because a caller that needs it should be using `wrap/2`.

      iex> Encryptor.Ecto.Tenant.put("merchant_7f3")
      :ok
      iex> Encryptor.Ecto.Tenant.get()
      {:ok, "merchant_7f3"}
  """
  @spec put(String.t()) :: :ok
  def put(tenant) when is_binary(tenant) do
    _previous = Process.put(@dict_key, tenant)
    :ok
  end

  @doc """
  Returns the tenant in scope for the calling process.

  `{:ok, tenant}` when one is in scope, `:error` when none is - the shape of
  `Map.fetch/2`, and never a `nil` tenant, which would be indistinguishable
  from a tenant whose identifier is genuinely absent.

      iex> Encryptor.Ecto.Tenant.clear()
      iex> Encryptor.Ecto.Tenant.get()
      :error
  """
  @spec get() :: {:ok, String.t()} | :error
  def get do
    case Process.get(@dict_key) do
      nil -> :error
      tenant when is_binary(tenant) -> {:ok, tenant}
    end
  end

  @doc """
  Returns the tenant in scope, or raises when none is.

  This is the call a host makes when it is about to cross a process boundary
  and needs the value to carry across (ADR-0001 decision 5b).

  The exception raised for an empty scope here is not a contract: it reports a
  host bug at the boundary, rather than the per-field failure the type modules
  raise, and it names no table or column because it knows none.

      iex> Encryptor.Ecto.Tenant.put("merchant_7f3")
      iex> Encryptor.Ecto.Tenant.fetch!()
      "merchant_7f3"
  """
  @spec fetch!() :: String.t()
  def fetch! do
    case get() do
      {:ok, tenant} ->
        tenant

      :error ->
        raise "no tenant in scope; call Encryptor.Ecto.Tenant.put/1 or " <>
                "Encryptor.Ecto.Tenant.wrap/2 at the boundary of this unit of work"
    end
  end

  @doc """
  Removes the tenant from the calling process's scope.

  Returns `:ok`, whether or not one was in scope. Clearing is for a process
  that owns its whole unit of work; a process that runs several should use
  `wrap/2`, which restores rather than clears.

      iex> Encryptor.Ecto.Tenant.put("merchant_7f3")
      iex> Encryptor.Ecto.Tenant.clear()
      :ok
      iex> Encryptor.Ecto.Tenant.get()
      :error
  """
  @spec clear() :: :ok
  def clear do
    _previous = Process.delete(@dict_key)
    :ok
  end

  @doc """
  Runs `fun` with `tenant` in scope, then restores the previous scope.

  Returns whatever `fun` returns. The previous scope is restored on the way
  out whether `fun` returns or raises, and "the previous scope" includes
  *no scope at all* - a `wrap/2` in a process that had no tenant leaves it with
  no tenant, not with a stale one.

  This is what makes the call safe in a pooled process and safe to nest:

      iex> Encryptor.Ecto.Tenant.put("merchant_7f3")
      iex> Encryptor.Ecto.Tenant.wrap("merchant_a19", fn ->
      ...>   Encryptor.Ecto.Tenant.fetch!()
      ...> end)
      "merchant_a19"
      iex> Encryptor.Ecto.Tenant.fetch!()
      "merchant_7f3"
  """
  @spec wrap(String.t(), (-> result)) :: result when result: var
  def wrap(tenant, fun) when is_binary(tenant) and is_function(fun, 0) do
    previous = Process.get(@dict_key)
    _replaced = Process.put(@dict_key, tenant)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  @spec restore(String.t() | nil) :: :ok
  defp restore(nil) do
    _previous = Process.delete(@dict_key)
    :ok
  end

  defp restore(tenant) do
    _previous = Process.put(@dict_key, tenant)
    :ok
  end
end
