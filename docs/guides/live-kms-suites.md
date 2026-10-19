# How to run the live KMS suites

This page is for maintainers of this repository. It is not part of the
published documentation: a host using the package never runs these suites.

Every key store and type test in the default suite runs without a KMS: Cloud KMS
rows resolve through an in-memory fake of the provider's HTTP seam, and every
other key comes from static material. The live suites are the one place this
package meets a real KMS. They are tagged, excluded by default in
`test/test_helper.exs`, and run by their own CI jobs. Both need Postgres, as
the `:database` tests do.

## Cloud KMS (the key store's `"gcp_kms_ciphertext"` rows)

The suite is `test/encryptor/ecto/gcp_kms_live_test.exs`, tagged
`:gcp_kms_integration`. It drives a scoped vault whose key store holds only
Cloud KMS rows, through an encrypted field:

- a row written: `Encryptor.Provider.GcpKms.provision/2` on the test key, and
  the row inserted into the key store's table;
- read back: a field written and read through that row;
- rotated: a version-2 row wrapped under the same key, which takes the
  writes while the value written under version 1 still reads;
- shredded: `Encryptor.Ecto.KeyStore.shred/3` deleting version 1 and then the
  scope, after which the values written under each deleted version no longer
  read.

It never creates a `CryptoKey` (every row it provisions names the test key)
and never destroys a key version: its shred is the row delete.

### What it needs

- A test key the credentials may encrypt and decrypt with. Use a dedicated
  key in a sandbox project, never a key that protects real data. The
  identity encryptor's live Cloud KMS suite uses will do.
- `GCP_KMS_KEY`, the key's full `CryptoKey` resource name, of the form
  `projects/*/locations/*/keyRings/*/cryptoKeys/*`.
- Credentials, read in this order:
  - the file `GOOGLE_APPLICATION_CREDENTIALS` names (a service account key, a
    Workload Identity Federation file, or a user's Application Default
    Credentials file);
  - otherwise the gcloud CLI's Application Default Credentials file, which
    `gcloud auth application-default login` writes.
- Postgres at `PGHOST` and `PGPORT` (default `localhost:5432`), as for the
  `:database` tests.

### Running it locally

From the repository root, with `GCP_KMS_KEY` exported in your shell,
Application Default Credentials in place and Postgres running:

```bash
gcloud auth application-default login
mix test --only gcp_kms_integration
```

With `GCP_KMS_KEY` unset or empty, the tests are reported as skipped rather
than failed, so the command is safe to run without credentials. Set
`ECTO_REQUIRE_GCP_KMS=1` to make an absent key name a failure instead, as CI
does.

Keep the key name out of anything you share. A failing test reports a call
kind, an HTTP status or a reason tag, and never a key name, a project, a key
ring or key material; do not add output that would.

### How CI runs it

The `gcp-kms-integration` job in `.github/workflows/ci.yml` starts the gate
job's Postgres service, authenticates with Workload Identity Federation (no
key file) through `google-github-actions/auth`, and reads the provider, the
service account and the key name from organisation secrets. The auth step
exports nothing to later steps; the test step is handed the credentials file
it wrote, and the job's last step removes that file. The job runs only when
all three secrets are present and the event is not from a fork or
Dependabot; otherwise it is a green job whose one step says it skipped. The
job is informational: no branch rule requires it.

## AWS KMS (an encrypted field on `Encryptor.Provider.Kms`)

The key store has no row shape AWS KMS wraps: its rows are either Cloud KMS
ciphertexts or engine messages a root vault on a `Static` provider unwraps.
So this suite drives the other place this package meets AWS KMS: an
encrypted field whose vault's provider is `Encryptor.Provider.Kms`.

The suite is `test/encryptor/ecto/aws_kms_live_test.exs`, tagged
`:aws_kms_integration`. It starts a scoped vault whose provider names one
test key, and checks:

- a write calls `GenerateDataKey` on the test key and puts a ciphertext in
  the column, and a read of that row calls `Decrypt` and hands back exactly
  the value written;
- the same row read under another scope does not load: KMS refuses the
  `Decrypt` with `InvalidCiphertextException`, twice, because the engine
  retries once under the message's stored context, and the field raises
  `Encryptor.Ecto.DecryptError`. This is the suite's wrong-key case: the
  read names the right key under a scope the data key was not generated
  for.

It never creates, disables or deletes a key.

The suite talks to KMS through its own small client
(`Encryptor.Ecto.AwsKmsLive.Client`, in `test/support/aws_kms_live.ex`),
handed to the provider as `:client`. This package declares no AWS
dependency, so the engine's shipped `ExAws` client is not in the build.

### What it needs

- A symmetric KMS key the credentials may call `GenerateDataKey` and
  `Decrypt` on. Use a dedicated key in a sandbox account, never a key that
  protects real data. The key encryptor's live AWS KMS suite uses will do.
- `KMS_KEY_ARN`, the key's full ARN, of the form
  `arn:aws:kms:<region>:<account>:key/<key id>`.
- Credentials in the environment: `AWS_ACCESS_KEY_ID` and
  `AWS_SECRET_ACCESS_KEY`, and `AWS_SESSION_TOKEN` when they are temporary
  (an assumed role's or an SSO session's always are). The suite reads these
  three variables and nothing else: no profile file, no instance metadata.
- Postgres, as above.

The requests go to the region the key's ARN names; `AWS_REGION` is not read.

### Running it locally

From the repository root, with `KMS_KEY_ARN` exported in your shell and
Postgres running. If your credentials live in a named profile or an SSO
session, the AWS CLI exports them as the variables above:

```bash
eval "$(aws configure export-credentials --profile <profile> --format env)"
mix test --only aws_kms_integration
```

With `KMS_KEY_ARN` unset or empty, the tests are reported as skipped rather
than failed, so the command is safe to run without credentials. Set
`ECTO_REQUIRE_AWS_KMS=1` to make an absent ARN a failure instead, as CI
does.

Keep the ARN and the credentials out of anything you share. A failing test
reports a call kind, an HTTP status or a reason tag; the client keeps only
the error type of a KMS refusal, because KMS's own message can name the key
and the caller. Do not add output that would print any of them.

### How CI runs it

The `aws-kms-integration` job in `.github/workflows/ci.yml` starts the gate
job's Postgres service and assumes a role with the job's GitHub OIDC token
(no static access key), the same role encryptor's live AWS KMS suite
assumes. The assumption is one silent run step calling
`aws sts assume-role-with-web-identity` for the credentials alone: it masks
each value before writing it, prints no part of the response and no message
from the call, and fails with one fixed line. It reads the role and the
key's ARN from organisation secrets. It runs only when both secrets are
present and the event is not from a fork or Dependabot; otherwise it is a
green job whose one step says it skipped. The job is informational: no
branch rule requires it.
