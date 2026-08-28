defmodule Mix.Tasks.Encryptor.Ecto.Verify do
  @shortdoc "Checks whether a plan's rows are all in the target state"

  @moduledoc """
  Classifies a plan's rows without writing anything.

      mix encryptor.ecto.verify PLAN [--prefix PREFIX] [--sample N | --sample all]

  `PLAN` is the plan module, positional and required, exactly as for
  `mix encryptor.ecto.migrate`. This task is a thin parser over
  `Encryptor.Ecto.Migrator.verify/2`; from a release, where there is no Mix:

      bin/my_app eval 'Encryptor.Ecto.Migrator.verify(MyApp.Encryption.CloakMigration, sample: :all)'

  Three jobs, one verb. It is the acceptance test at the end of a rotation
  (ADR-0004 decision 8, step 6), it is what a host runs on a schedule to
  detect drift, and exiting 0 over `--sample all` is decision 5's primary
  signal that the mixed window has closed and that dropping `legacy:` is due.

  ## Flags

  | Flag | `verify/2` option | |
  |---|---|---|
  | `--sample N` / `--sample all` | `:sample` | `all` by default: the whole scope, visited with the same keyset pagination a run uses. `N` is a random sample of that many rows per field |
  | `--prefix PREFIX` | `:prefix` | The one schema prefix to visit; the repo's default when absent. Present because a verification that silently checked a different prefix than the pass wrote to would be worse than no verification |

  **These two and no others.** `--only-tenant`, `--except-tenant`, `--only`,
  `--batch-size`, `--resume`, `--no-checkpoint` and `--on-error` are
  `mix encryptor.ecto.migrate` flags, and passing one here is a usage error
  rather than a silently ignored argument. `verify/2` takes `:sample` and
  `:prefix`; a task flag with no library option behind it would be a
  capability the release path could not reproduce, which is the one thing
  ADR-0004 decision 6 forbids the tasks.

  ## Exit codes

  | | |
  |---|---|
  | `0` | Every row it saw was `:already_target` or `:null` |
  | `1` | Something was not: a readable legacy row, an unreadable row, or any later class. This arm is **stricter** than `mix encryptor.ecto.migrate`'s - a table of readable legacy rows is a green dry run and a red verification, and the acceptance test has to be the second |
  | `2` | Usage error, a plan that will not compile, or a verification that could not start |

  A verification never halts on a row: it runs with `on_error: :continue`, so
  a table with unreadable rows produces a count of them rather than a report
  that stops at the first. It writes no checkpoint and needs no checkpoint
  table.
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
    case CLI.parse_verify(argv) do
      {:ok, {plan, opts}} -> boot_and_verify(plan, opts)
      {:error, message} -> CLI.usage_error(message)
    end
  end

  @spec boot_and_verify(module(), keyword()) :: 0 | 1 | 2
  defp boot_and_verify(plan, opts) do
    case CLI.boot() do
      :ok -> CLI.run_pass(fn -> Migrator.verify(plan, opts) end)
      {:error, message} -> CLI.usage_error(message)
    end
  end
end
