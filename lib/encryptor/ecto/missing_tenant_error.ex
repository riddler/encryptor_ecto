defmodule Encryptor.Ecto.MissingTenantError do
  @moduledoc """
  Raised when a field declared `tenant: :scope` is dumped or loaded with no
  tenant in the process scope (ADR-0001 decision 6).

  This is the loud, early failure decision 5 chose over a configured default
  tenant. The failure it replaces is a row written under the wrong key by a
  background job that forgot to set scope - durable, silent, and recoverable
  only by knowing which rows to re-encrypt. An exception on the first test run
  is the cheap version of that.

  The struct carries no tenant, because there was none to carry.
  """

  use Encryptor.Ecto.Error

  @doc false
  @spec headline() :: String.t()
  def headline, do: "no tenant in scope for an encrypted field declared tenant: :scope"
end
