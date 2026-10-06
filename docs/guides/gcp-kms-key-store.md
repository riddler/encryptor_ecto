# How to keep scope keys in Google Cloud KMS through the key store

`Encryptor.Ecto.KeyStore` reads a scope's master keys out of the
wrapped-key table. By default each row's wrapping is an engine message
produced by your root vault. This guide is for the other shape the table
holds: a row whose wrapping is a Google Cloud KMS ciphertext, produced by
`Encryptor.Provider.GcpKms` under a `CryptoKey` of its own, so that the
wrapping key never leaves Cloud KMS and destroying it is a Cloud KMS
operation.

It takes you from an empty key ring to a scope whose values read and write
through a scoped vault, and then through the shred: destroying the key
version, deleting the row, and what your application sees at each step.

It assumes a scoped vault already reading from the key store - the
`## Configuring it` section of `Encryptor.Ecto.KeyStore` - and a wrapped-key
table created by `mix encryptor.ecto.gen.key_store_migration`. A table
created before the `wrapping_shape` and `key_id` columns existed needs
`mix encryptor.ecto.gen.key_store_shape_migration` first. What a scope is
here: the unit your scoped vault partitions keys by, which in this release
is the scope selector you pass as `key:`, stored on each row as its
keyed reference `scope_ref`. Every scope gets its own `CryptoKey`.

## Step 1. Create the key ring, and grant the service account

`Encryptor.Provider.GcpKms` never creates a key ring and never writes IAM
(its `## What it never does`). Both are yours, once per environment:

- A key ring in the project and location you will name in configuration. A
  key ring cannot be deleted; keep it out of any state a routine destroy
  would touch.
- For the service account your application runs as:
  `cloudkms.cryptoKeyVersions.useToEncrypt` and `useToDecrypt` on the ring,
  and `cloudkms.cryptoKeys.create` for whichever process provisions scopes.

## Step 2. Run a Goth token server

The provider asks a token server for a bearer token on every call. Add
`goth` to your dependencies (`encryptor` declares it optional,
`{:goth, "~> 1.4"}`) and start a named server in your supervision tree:

```elixir
children = [
  MyApp.Repo,
  {Goth, name: MyApp.Goth, source: {:service_account, credentials}},
  MyApp.ScopedVault
]
```

`credentials` is the decoded service-account JSON; on a platform with a
metadata server, Goth's metadata source does the same without a key file.
Start it before anything that reads or writes encrypted data: every
resolution of a GCP row fetches a token from it. `goth: MyApp.Goth` in the next step names this server. Any module
exporting `fetch/1` with Goth's return shape can stand in for it, as
`goth: {Module, name}`.

## Step 3. Give the key store the GCP client

The provider also needs an HTTP client module exporting `request/5` - a
thin wrapper over whichever client you already run; the contract is
`Encryptor.Provider.GcpKms`'s `### The HTTP client contract`. Then add
`:gcp_kms` to the key store's options:

```elixir
provider:
  {Encryptor.Ecto.KeyStore,
   repo: MyApp.Repo,
   root_vault: MyApp.RootVault,
   reference_subkey: subkey,
   gcp_kms: [
     project: "myapp-prod",
     location: "us-east1",
     key_ring: "encryptor-scope-keys",
     http_client: MyApp.KmsHttp,
     goth: MyApp.Goth
   ]}
```

Leave `:reference_subkey` and `:store` out of `:gcp_kms`: the key store
supplies both, and naming either there is refused at start as
`{:invalid_config, :gcp_kms, {:supplied_by_key_store, key}}`. The rest is
checked by the provider's own `init/1` when the vault starts, so a missing
option or an unloaded module fails the boot rather than the first read.

Engine-message rows keep working beside GCP rows in the same table and the
same scope; the key store picks the unwrap path per row from its
`wrapping_shape` (`Encryptor.Ecto.KeyStore`, "The table").

## Step 4. Provision a scope's key and store its row

The key store mints nothing, so provisioning is a call you make: the
provider's `provision/2` creates the scope's `CryptoKey`, generates 32 bytes,
wraps them under it, and returns the row. You insert that row with
`wrapping_shape` set to `"gcp_kms_ciphertext"`:

```elixir
def provision_gcp_key(scope_id) do
  {:ok, gcp} =
    Encryptor.Provider.GcpKms.init(
      gcp_kms_opts() ++ [reference_subkey: subkey(), store: fn _ref -> {:ok, []} end]
    )

  with {:ok, row} <- Encryptor.Provider.GcpKms.provision(gcp, scope_id) do
    MyApp.Repo.insert_all("encryptor_wrapped_keys", [
      row
      |> Map.put(:wrapping_shape, "gcp_kms_ciphertext")
      |> Map.to_list()
    ])
  end
end
```

`gcp_kms_opts()` is the same keyword list as the key store's `:gcp_kms`,
and `subkey()` the same reference subkey; with a different subkey the row
would be filed under a `scope_ref` the vault never asks for. The `store:`
function is required by `init/1` and unused by `provision/2`.

The provider answers the reference as `:scope_ref`, which is the table's
column of the same name (ADR-0006 Amendment A), so the row goes in as it
comes back, with `wrapping_shape` added.

What you get back:

- `key_id` is the `CryptoKey` id: by default `t-` and a base32 digest of
  the namespace and the selector, never the selector itself. It goes in the `key_id` column. The full
  resource name, for a runbook, is
  `Encryptor.Provider.GcpKms.crypto_key_name/2` of the same state and
  selector.
- `version` is `1`. `provision/2` mints version 1 and nothing else, and
  creates the `CryptoKey` with no rotation schedule, so it has one
  `CryptoKeyVersion`.
- The wrapping is bound to the row's `scope_ref`, `version` and `namespace`
  as additional authenticated data, so a row edited or moved to another
  scope does not decrypt.

`provision/2` is not safe to call concurrently for one selector (its
`## Provisioning`). The table's unique index on `{scope_ref, version}`
refuses the second insert, and the losing call's wrapping is never stored.
Make provisioning part of your scope's onboarding transaction.

## Step 5. Read and write as usual

Nothing changes at the call sites: encrypted fields and direct vault calls
resolve the key through the key store, which hands the GCP row to the
provider for one `Decrypt`. Every resolution of a GCP row is one Cloud KMS
round trip.

## Step 6. Shred a scope

A shred makes every value written under the scope's key unreadable,
including the copies in your backups: the wrapping key is in Cloud KMS, not
in the backup. It is two operations, in this order: destroying the key
version is a Cloud KMS call you make, because this package never calls
Cloud KMS to destroy anything; deleting the row is
`Encryptor.Ecto.KeyStore.shred/3`.

Before either, record the decision. `encryptor`'s ADR-0005 runbook P3, the
procedure for a whole scope, requires a recorded human decision before a
shred, and `shred/3` leaves that precondition to you.

**First, destroy the key version.**

```sh
gcloud kms keys versions destroy 1 \
  --location us-east1 --keyring encryptor-scope-keys --key t-<digest>
```

`gcloud kms keys versions list` on the same key shows every version to
destroy; a key provisioned as above has one.

**Then delete the row** with `shred/3`, on the scoped vault that reads it:

```elixir
{:ok, shred} =
  Encryptor.Ecto.KeyStore.shred(MyApp.ScopedVault, scope_id, version: :all)
```

`version: :all` deletes every row for the scope's `scope_ref` in one
transaction that locks them first, so the versions the record names are
the versions deleted. The rows are deleted from the repo, table and prefix
the vault's key store was started with, and from no other. By default the
call then waits out the vault's cache `max_age` before it returns, and
returns at once for a vault configured `cache: false`; pass `drain: :skip`
if you restart the vault on every node instead. The destroyed version does
not get in the way: the shred reads the scope's version numbers and never
unwraps a row, so it makes no Cloud KMS call.

The `Encryptor.Ecto.KeyStore.Shred` it returns is the change record: the
`versions` deleted, the `scope_ref` (the column's value, never your
selector), `deleted_at` and `drained_at`. Keep it beside the decision. A
refusal deletes nothing: `{:unknown_key, selector}` for a scope with no
row, `{:key_unavailable, selector}` when the database could not be asked
and a retry could work, `{:not_a_key_store_vault, vault}` for a vault
whose provider is not the key store; `shred/3`'s documentation lists the
rest. `version: n` deletes one version instead and refuses the scope's
newest; a scope provisioned as above has only version 1, so its shred is
`version: :all`.

Do not replace the call with a hand-written `delete_all`: that takes no
lock, waits for no drain and leaves no record.

The row delete is not optional. Destroying the key is not full erasure: the
scope's `scope_ref` is a permanent pseudonym that sits in every message
header and every retained backup, so the row deletion stays as mandatory as
it is for an engine-message row (`Encryptor.Provider.GcpKms`, "The shred,
and why it is not a function here").

### The restore window

A destroyed version is not gone at once. It sits in `DESTROY_SCHEDULED` for
the `CryptoKey`'s scheduled-destruction duration, and a
`gcloud kms keys versions restore` during that time brings it back (Cloud
KMS leaves a restored version disabled; enable it to use it). `provision/2`
does not set the duration, so the service's default applies, and it is fixed
when the key is created. The `Encryptor.Provider.GcpKms` moduledoc in
`encryptor` 0.6.0 and Cloud KMS's own reference for
`destroyScheduledDuration` both give that default as 30 days. Read it off
your key with `gcloud kms keys describe` rather than trusting either.

A restore only helps while the row still holds its wrapping. Once the row is
deleted there is nothing for a restored version to decrypt, and the key
store answers `{:unknown_key, selector}` either way. Treat the window as a
delay, not as an undo you plan around.

### What your application sees

| After | `decryption_keys/2` and `encryption_key/2` | a scoped vault's `decrypt/2` |
|---|---|---|
| provisioning | `{:ok, ...}` | the value |
| destroying the version, row still present | `{:error, {:invalid_key_descriptor, {:kms_refused, 400}}}` | `{:error, %Encryptor.Error{reason: {:invalid_key_descriptor, {:kms_refused, 400}}}}` |
| `shred/3` deleting the row | `{:error, {:unknown_key, selector}}` | `{:error, %Encryptor.Error{reason: {:unknown_key, selector}}}` |

The middle row is a refusal, not an outage. Cloud KMS answers a `Decrypt`
under a destroyed version with HTTP 400, and `Encryptor.Provider.GcpKms`, in
`encryptor` 0.6.1 (the version this package pins), reports a 400 or a 404 as
`{:invalid_key_descriptor, {:kms_refused, status}}`: the permanent family,
not the `{:key_unavailable, selector}` a caller retries. The key store
returns the provider's answer unrelabelled, as ADR-0005 Amendment A5 sets
out for a GCP row. "When Cloud KMS refuses, or does not answer" below covers
the same answers outside a shred.

So between the two shred steps a retry loop keyed on `:key_unavailable`
leaves the scope alone. Call `shred/3` promptly after the destroy all the
same: until the row is deleted, a restore inside the window above brings the
values back.

A shred is also not immediate: `Encryptor.Vault`'s documentation of
`suspend/2` notes that, unlike a suspension, a shred's runbook has to drain
the vault's materials cache, and that drain is what `shred/3` waits for by
default. The answers above are what a vault configured with `cache: false`
sees on the very next call.

## When Cloud KMS refuses, or does not answer

Two things about a GCP row are easy to miss until they happen: an IAM
denial reads as retryable, and an outage costs a wait per row.

### Which refusals are permanent

`Encryptor.Provider.GcpKms`, in `encryptor` 0.6.1 (the version this package
pins), answers a failed `Decrypt` by its HTTP status (its moduledoc's
"What a failed `Decrypt` answers"), and the key store returns that answer
unrelabelled (ADR-0005 Amendment A5):

- **HTTP 400 or 404** is `{:invalid_key_descriptor, {:kms_refused,
  status}}`, which no retry changes: a destroyed key version (the shred's
  middle row above), a version an operator disabled, a key that is not
  there, or a row whose `scope_ref`, `version` or `namespace` no longer
  matches the additional authenticated data its wrapping was bound to. Two
  of these an operator can reverse: a disabled version, by enabling it
  again, and a destroyed one inside the restore window above, by restoring
  it.
- **HTTP 403** stays `{:key_unavailable, selector}`, as an outage does: a
  service account that lacks `useToDecrypt` on the ring (Step 1), or whose
  grant was revoked. A revoked grant is how a provider-level suspension is
  made, so the term is the retryable one, and no retry succeeds until the
  grant is back.

What your application sees depends on which row refuses, because of the
key store's "one bad row is not the whole store" rule:

- **The newest row refuses.** `encryption_key/2` unwraps the newest row and
  no other, so every write for the scope answers that row's term until the
  row or the grant is fixed, or the scope is shredded. `decryption_keys/2`
  still answers with any older rows that unwrap, and answers the newest
  row's term only when none does.
- **An older row refuses.** `decryption_keys/2` leaves it out and answers
  with the rest; values written under that version do not decrypt, and
  nothing else fails.

A caller that retries on `:key_unavailable` cannot tell a missing grant
from an outage by the term. Bound its retries, and when one scope keeps
answering it while others read and write normally, check the service
account's grant before treating it as an outage. A `:kms_refused` answer
needs no retry: check that scope's key versions and rows instead.

### An outage costs one request timeout per GCP row

Each GCP row is unwrapped by its own `Decrypt` request, and the request
waits up to the provider's `:timeout` - per call, 5,000 ms unless you set
it in `:gcp_kms` - before it answers (`Encryptor.Provider.GcpKms`'s
`## Configuration`; the value is handed to your HTTP client as its `timeout:`
option, so the bound is only as good as your client's handling of it).
The key store unwraps a scope's rows one after another, newest first, and
tries every row before it answers (`Encryptor.Ecto.KeyStore`'s private
`unwrap_all/3`).

So while Cloud KMS does not answer:

- `decryption_keys/2` for a scope with N GCP rows waits about N times the
  timeout before it answers `{:key_unavailable, selector}`: with the
  default and three versions, about 15 seconds.
- `encryption_key/2` waits about one timeout, because it unwraps the newest
  row only.

That wait is paid on every call that reaches the provider during the
outage. If your callers have a deadline of their own, set `:timeout` in
`:gcp_kms` with the number of GCP versions a scope carries in mind, and
keep the count down: a version whose values have all been rewritten under
a newer one can be shredded with `shred/3`'s `version: n`.

## What this guide checked

`test/encryptor/ecto/key_store_gcp_shred_repo_test.exs` runs Steps 4 to 6
against a fake of the provider's HTTP seam: provision, write, read, destroy,
restore, destroy again, delete the row with `shred/3`, and every answer in
the table above.
