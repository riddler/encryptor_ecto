defmodule Encryptor.Ecto.VaultProfileError do
  @moduledoc """
  Raised when a field declared `tenant: :none` names a `:tenant`-profile vault
  (ADR-0001 decision 5e, acceptance amendment 3).

  A `:none` field omits the tenant key from the vault call entirely. A
  `:tenant`-profile vault carries the tenant reference in its required set and
  refuses an operation without it, so "a tenant vault with the pair omitted"
  is not a representable configuration: the pairing is wrong, not merely
  unlucky, and the host runs a second `:single`-profile vault for its global
  fields.

  ## Why the check is worth its per-call cost

  Left unchecked, the misconfiguration does still fail on the first write -
  but as whatever the vault happens to refuse first, which depends on the
  vault's key provider rather than on the pairing. Removing this check from
  this package's own fixtures turns the failure into an
  `Encryptor.Ecto.EncryptError` reading `{:invalid_selector, :default}`, a
  provider complaining about a selector nobody wrote; a provider that accepts
  that selector gets one step further and fails the required-context check
  instead, as `Encryptor.Ecto.MissingContextError`. Neither names the field's
  `tenant: :none`, neither names the vault's profile, and neither says what to
  change.

  This exception exists so the pairing rule fails in its own words, naming the
  field, the vault it named, and the profile that vault resolved to. It is a
  distinct member of the family rather than a distinct kind of thing: the
  shared shape, the redaction rules, and the prohibition in
  `Encryptor.Ecto.Error` all apply unchanged.

  ## Why it is raised from `dump/3` and `load/3` rather than at compile time

  `:context_profile` is ordinary vault configuration, and it arrives through
  the same five layers as everything else the vault resolves - three of which
  (application environment, `start_link/1` options, the optional `init/1`) do
  not exist when the vault module is compiled, let alone when a downstream
  Ecto type is. The authoritative value is the frozen
  `Encryptor.Vault.Config` struct the vault publishes at start, read through
  `Encryptor.Vault.Config.fetch/1`.

  Reading the `use` options at compile time would be right in the common case
  and wrong in exactly the case a host varies the profile per environment,
  which is worse than checking later: it is a check that holds until it
  matters. Deriving the rule from the running vault's own configuration is the
  same one-source-of-truth property the tenant reference gets, so the check
  and the vault it checks cannot disagree.

  ## `:vault` and `:profile`

  `:vault` is the vault module the declaration named, and `:profile` is the
  profile it resolved to at start. Both are module and atom values from the
  declaration and the configuration; neither is key material.
  """

  use Encryptor.Ecto.Error, extra_fields: [vault: nil, profile: nil]

  @doc false
  @spec headline() :: String.t()
  def headline do
    "a field declared tenant: :none names a :tenant-profile vault; point it at " <>
      "a :single-profile vault instead"
  end

  @doc false
  def extra_detail(%__MODULE__{vault: vault, profile: profile}) do
    [{"vault", inspect(vault)}, {"vault profile", inspect(profile)}]
  end
end
