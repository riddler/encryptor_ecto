defmodule Encryptor.Ecto.KeyStore.Shred do
  @moduledoc """
  What one `Encryptor.Ecto.KeyStore.shred/3` destroyed, and when it took
  effect.

  A shred is irreversible, and `encryptor`'s enc-ADR-0005 asks the operator
  to record what was destroyed in the change record (P3 step 1: "Record the
  count and the version numbers"). This struct is that record, returned by
  the call that performed the delete, so a host certifies from what the store
  actually removed rather than from what it asked for (ADR-0007 decision 4).

  | Field | |
  |---|---|
  | `:vault` | the vault whose key store was shredded |
  | `:procedure` | `:scope` for enc-ADR-0005's P3 (every version) or `:version` for its P4 (one version) |
  | `:scope_ref` | `Encryptor.Envelope.scope_ref/2` of the selector: the value in the table's `tenant_ref` column. Never the selector itself |
  | `:versions` | the versions whose rows were deleted, ascending |
  | `:remaining` | the versions still live for the scope after the delete, ascending. `[]` after P3 |
  | `:table`, `:prefix` | where the rows were deleted from, as the key store is configured |
  | `:deleted_at` | when the delete committed, UTC |
  | `:drained_at` | when every vault serving the scope has stopped decrypting under a deleted version: `:deleted_at` plus the vault's cache `max_age`, or `:deleted_at` for a vault with `cache: false` |
  | `:drain` | `:waited` when the call returned at or after `:drained_at`, `:skipped` when the caller asked it not to wait |

  `:drained_at` is the moment enc-ADR-0005's P3 step 3 and P4 step 2 are
  complete for a host that waits rather than restarts, and it holds for every
  node only when every node runs the vault with the same `max_age`, which is
  what one vault module's configuration gives. A host that restarts its vaults
  instead completes the drain at the restart, and a record with
  `drain: :skipped` says the call did not wait for it.

  The selector is deliberately not a field. A shred record is written into a
  change log that outlives the scope, and the scope reference is the value the
  key store keys the scope's rows by without publishing the host's identifier
  beside them.
  """

  @enforce_keys [
    :vault,
    :procedure,
    :scope_ref,
    :versions,
    :remaining,
    :table,
    :prefix,
    :deleted_at,
    :drained_at,
    :drain
  ]
  defstruct @enforce_keys

  @typedoc "Which of enc-ADR-0005's two destroying procedures ran."
  @type procedure :: :scope | :version

  @type t :: %__MODULE__{
          vault: module(),
          procedure: procedure(),
          scope_ref: String.t(),
          versions: [pos_integer(), ...],
          remaining: [pos_integer()],
          table: String.t(),
          prefix: String.t() | nil,
          deleted_at: DateTime.t(),
          drained_at: DateTime.t(),
          drain: :waited | :skipped
        }
end
