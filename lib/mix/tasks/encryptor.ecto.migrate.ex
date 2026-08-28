defmodule Mix.Tasks.Encryptor.Ecto.Migrate do
  @shortdoc "Rewrites the ciphertext columns a plan names"

  @moduledoc """
  Runs a migration plan, in exactly one of the two modes.

      mix encryptor.ecto.migrate PLAN --mode dry-run|write
                                      [--batch-size N] [--resume] [--no-resume]
                                      [--prefix PREFIX] [--no-checkpoint]
                                      [--only Schema:field,Schema:field]
                                      [--only-tenant ID] [--except-tenant ID]
                                      [--on-error halt|continue]

  `PLAN` is the plan module - the one that `use Encryptor.Ecto.Migration` -
  positional and required. The plan is the unit of work (ADR-0002
  decision 2): no flag names a schema, a field or a repo instead of it.

  This task is a thin parser over `Encryptor.Ecto.Migrator.run/2`, and the
  library function is the real interface. A production host runs releases and
  a release has no Mix, so the same pass runs there as:

      bin/my_app eval 'Encryptor.Ecto.Migrator.run(MyApp.Encryption.CloakMigration, mode: :dry_run)'

  Every flag below maps one-to-one onto an option of `run/2`. The task adds no
  capability the library function lacks (ADR-0004 decision 6), which is what
  keeps the release path a first-class one rather than a degraded one.

  ## Flags

  | Flag | `run/2` option | |
  |---|---|---|
  | `--mode dry-run\\|write` | `:mode` | **Required, no default.** `dry-run` performs every read, probe, decrypt and encrypt and discards the write |
  | `--batch-size N` | `:batch_size` | Rows per transaction; 500 by default |
  | `--resume` / `--no-resume` | `:resume` | Start after the recorded checkpoint cursor. Off by default |
  | `--prefix PREFIX` | `:prefix` | The one schema prefix to visit; the repo's default when absent. No mode enumerates prefixes - a host with several loops the command over its own list |
  | `--no-checkpoint` | `:checkpoint` | `:none`, the documented degraded mode for a host that will not add the checkpoint table: every run is a full scan, which probe-first idempotence makes correct rather than merely tolerable |
  | `--only Schema:field,Schema:field` | `:only` | Narrow the plan to these fields, in the plan's own order |
  | `--only-tenant ID` | `:only_tenants` | Repeatable. Visit only these tenants |
  | `--except-tenant ID` | `:except_tenants` | Repeatable. Visit every tenant but these |
  | `--on-error halt\\|continue` | `:on_error` | `continue` records the failure and finishes the pass. `halt` by default |

  `--resume` with `--no-checkpoint` is a usage error: resuming from a
  checkpoint that was never written is a request with no meaning.

  There is deliberately no flag for `run/2`'s `:checkpoint_table` or
  `:progress`. The grammar is fixed by ADR-0004 decision 6 and widening it is
  an amendment to that record, not a convenience: a host that renamed the
  checkpoint table passes `checkpoint_table:` to `run/2` from an `eval`.

  ## Exit codes

  | | |
  |---|---|
  | `0` | The pass completed and recorded no failures |
  | `1` | The pass ran and found something: failures recorded under `--on-error continue`, or rows an operator has to decide about. A dry run that finds `:undecryptable` rows exits 1, because "the rehearsal found a problem" is not success |
  | `2` | Usage error, a plan that will not compile, no mode given, or a run that could not start at all - a missing checkpoint table, a tenant filter against a rewrite with no tenant column |

  ## What it prints

  The report: one line per class of `Encryptor.Ecto.Migrator.Report`, the
  concurrent-write count, the failure count, and one line per recorded failure
  naming the schema, the field, the primary key and the reason. Never a
  plaintext, never ciphertext bytes, never key material.
  """

  use Mix.Task

  alias Encryptor.Ecto.Migrator
  alias Encryptor.Ecto.Migrator.CLI

  @impl Mix.Task
  def run(argv) do
    argv |> main() |> CLI.halt()
  end

  @doc false
  @spec main([String.t()]) :: 0 | 1 | 2
  def main(argv) do
    case CLI.parse_migrate(argv) do
      {:ok, {plan, opts}} -> boot_and_run(plan, opts)
      {:error, message} -> CLI.usage_error(message)
    end
  end

  @spec boot_and_run(module(), keyword()) :: 0 | 1 | 2
  defp boot_and_run(plan, opts) do
    case CLI.boot() do
      :ok -> CLI.run_pass(fn -> Migrator.run(plan, opts) end)
      {:error, message} -> CLI.usage_error(message)
    end
  end
end
