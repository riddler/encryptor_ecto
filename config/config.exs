import Config

# This file configures nothing but the test harness, and a host that depends
# on `encryptor_ecto` never reads it - a dependency's config/ is not loaded by
# the project that depends on it. It is here because the `:database`-tagged
# tests need a repository, and a repository needs an `otp_app` entry.
#
# Every value comes from the standard PG* variables, defaulting to the
# conventional local endpoint. That is deliberately the same source
# `Encryptor.Ecto.TestDatabase`'s reachability probe reads, so the probe and
# the connection can never disagree about which server the suite is talking
# about: a developer who points PGPORT at a container gets both the probe and
# the repository pointed there by the one export, and CI's job-level env does
# the same for the service container.
if config_env() == :test do
  config :encryptor_ecto, ecto_repos: [Encryptor.Ecto.TestRepo]

  config :encryptor_ecto, Encryptor.Ecto.TestRepo,
    username: System.get_env("PGUSER", "postgres"),
    password: System.get_env("PGPASSWORD", "postgres"),
    hostname: System.get_env("PGHOST", "localhost"),
    port: String.to_integer(System.get_env("PGPORT", "5432")),
    database: System.get_env("PGDATABASE", "encryptor_ecto_test"),
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 5,
    log: false
end
