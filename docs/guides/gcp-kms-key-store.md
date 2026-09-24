# How to keep tenant keys in Google Cloud KMS through the key store

`Encryptor.Ecto.KeyStore` reads a tenant's master keys out of the
wrapped-key table. By default each row's wrapping is an engine message
produced by your root vault. This guide is for the other shape the table
holds: a row whose wrapping is a Google Cloud KMS ciphertext, produced by
`Encryptor.Provider.GcpKms` under a `CryptoKey` of its own, so that the
wrapping key never leaves Cloud KMS and destroying it is a Cloud KMS
operation.

It takes you from an empty key ring to a tenant whose values read and write
through a tenant vault, and then through the shred: destroying the key
version, deleting the row, and what your application sees at each step.

It assumes a tenant vault already reading from the key store - the
`## Configuring it` section of `Encryptor.Ecto.KeyStore` - and a wrapped-key
table created by `mix encryptor.ecto.gen.key_store_migration`. A table
created before the `wrapping_shape` and `key_id` columns existed needs
`mix encryptor.ecto.gen.key_store_shape_migration` first. What a scope is
here: the unit your tenant vault partitions keys by, which in this release
is the tenant selector you pass as `key:`, stored on each row as its
keyed reference `tenant_ref`. Every scope gets its own `CryptoKey`.

## Step 1. Create the key ring, and grant the service account

`Encryptor.Provider.GcpKms` never creates a key ring and never writes IAM
(its `## What it never does`). Both are yours, once per environment:

- A key ring in the project and location you will name in configuration. A
  key ring cannot be deleted; keep it out of any state a routine destroy
  would touch.
- For the service account your application runs as:
  `cloudkms.cryptoKeyVersions.useToEncrypt` and `useToDecrypt` on the ring,
  and `cloudkms.cryptoKeys.create` for whichever process provisions tenants.

## Step 2. Run a Goth token server

The provider asks a token server for a bearer token on every call. Add
`goth` to your dependencies (`encryptor` declares it optional,
`{:goth, "~> 1.4"}`) and start a named server in your supervision tree:

```elixir
children = [
  MyApp.Repo,
  {Goth, name: MyApp.Goth, source: {:service_account, credentials}},
  MyApp.TenantVault
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
     key_ring: "encryptor-tenant-keys",
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
same tenant; the key store picks the unwrap path per row from its
`wrapping_shape` (`Encryptor.Ecto.KeyStore`, "The table").

## Step 4. Provision a scope's key and store its row

The key store mints nothing, so provisioning is a call you make: the
provider's `provision/2` creates the scope's `CryptoKey`, generates 32 bytes,
wraps them under it, and returns the row. You insert that row with
`wrapping_shape` set to `"gcp_kms_ciphertext"`:

```elixir
def provision_gcp_key(tenant_id) do
  {:ok, gcp} =
    Encryptor.Provider.GcpKms.init(
      gcp_kms_opts() ++ [reference_subkey: subkey(), store: fn _ref -> {:ok, []} end]
    )

  with {:ok, row} <- Encryptor.Provider.GcpKms.provision(gcp, tenant_id) do
    MyApp.Repo.insert_all("encryptor_wrapped_keys", [
      row |> Map.put(:wrapping_shape, "gcp_kms_ciphertext") |> Map.to_list()
    ])
  end
end
```

`gcp_kms_opts()` is the same keyword list as the key store's `:gcp_kms`,
and `subkey()` the same reference subkey; with a different subkey the row
would be filed under a `tenant_ref` the vault never asks for. The `store:`
function is required by `init/1` and unused by `provision/2`.

What you get back:

- `key_id` is the `CryptoKey` id: by default `t-` and a base32 digest of
  the namespace and the selector, never the selector itself. It goes in the `key_id` column. The full
  resource name, for a runbook, is
  `Encryptor.Provider.GcpKms.crypto_key_name/2` of the same state and
  selector.
- `version` is `1`. `provision/2` mints version 1 and nothing else, and
  creates the `CryptoKey` with no rotation schedule, so it has one
  `CryptoKeyVersion`.
- The wrapping is bound to the row's `tenant_ref`, `version` and `namespace`
  as additional authenticated data, so a row edited or moved to another
  scope does not decrypt.

`provision/2` is not safe to call concurrently for one selector (its
`## Provisioning`). The table's unique index on `{tenant_ref, version}`
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
in the backup. This package ships no verb for it; it is two operations you
run, in this order.

**First, destroy the key version.**

```sh
gcloud kms keys versions destroy 1 \
  --location us-east1 --keyring encryptor-tenant-keys --key t-<digest>
```

`gcloud kms keys versions list` on the same key shows every version to
destroy; a key provisioned as above has one.

**Then delete the row**, every row for the scope's `tenant_ref`:

```elixir
MyApp.Repo.delete_all(
  from(k in "encryptor_wrapped_keys", where: k.tenant_ref == ^tenant_ref)
)
```

The row delete is not optional. Destroying the key is not full erasure: the
scope's `tenant_ref` is a permanent pseudonym that sits in every message
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
`encryptor` 0.4.1 gives that default as 24 hours; Cloud KMS's own reference
for `destroyScheduledDuration` gives 30 days. Read it off your key with
`gcloud kms keys describe` rather than trusting either.

A restore only helps while the row still holds its wrapping. Once the row is
deleted there is nothing for a restored version to decrypt, and the key
store answers `{:unknown_key, selector}` either way. Treat the window as a
delay, not as an undo you plan around.

### What your application sees

| After | `decryption_keys/2` and `encryption_key/2` | a tenant vault's `decrypt/2` |
|---|---|---|
| provisioning | `{:ok, ...}` | the value |
| destroying the version, row still present | `{:error, {:key_unavailable, selector}}` | `{:error, %Encryptor.Error{reason: {:key_unavailable, selector}}}` |
| deleting the row | `{:error, {:unknown_key, selector}}` | `{:error, %Encryptor.Error{reason: {:unknown_key, selector}}}` |

The middle row needs care. `{:key_unavailable, selector}` is the answer the
provider contract reserves for "could not ask, and asking again later could
work" - the one a caller retries. Here it also covers a version that will
never decrypt again, because `Encryptor.Provider.GcpKms` answers every
refused `Decrypt` - an unreachable service, a row that no longer matches its
binding, a destroyed version - with that one term, and the key store
returns it unrelabelled. That behaviour is ADR-0005 Amendment A5, which is
**proposed, not accepted**: the accepted decision 5 would call a found row
that does not unwrap `{:invalid_key_descriptor, :unwrap_failed}`, and the
amendment records why the key store cannot tell the two apart through the
provider's public answer.

So between the two shred steps a retry loop keyed on `:key_unavailable`
will spin on a scope that is gone. Delete the row promptly after the
destroy, and keep the scope out of your retry paths while the shred runs.

A shred is also not immediate: `Encryptor.Vault`'s documentation of
`suspend/2` notes that, unlike a suspension, a shred's runbook has to drain
the vault's materials cache. The answers above are what a vault configured with
`cache: false` sees on the very next call.

## What this guide checked

`test/encryptor/ecto/key_store_gcp_shred_repo_test.exs` runs Steps 4 to 6
against a fake of the provider's HTTP seam: provision, write, read, destroy,
restore, destroy again, delete the row, and every answer in the table above.
