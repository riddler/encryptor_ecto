defmodule Encryptor.Ecto.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/riddler/encryptor_ecto"

  def project do
    [
      app: :encryptor_ecto,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Encryptor.Ecto",
      description:
        "Encrypted Ecto types for the Encryptor vault - drop-in field encryption with a two-line migration",
      source_url: @source_url,
      docs: docs(),
      package: package(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:ex_unit]],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Hexdocs configuration. These paths are read off the publisher's disk at
  # `mix docs` time and need no entry in package()'s files: list - the docs
  # tarball hexdocs hosts is built separately from the package tarball
  # `mix deps.get` fetches.
  defp docs do
    [
      name: "Encryptor.Ecto",
      source_ref: "v#{@version}",
      canonical: "https://hexdocs.pm/encryptor_ecto",
      source_url: @source_url,
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md"
      ],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp package do
    [
      name: "encryptor_ecto",
      licenses: ["Apache-2.0"],
      files: ~w(lib mix.exs .formatter.exs README.md LICENSE CHANGELOG.md),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp deps do
    [
      {:ecto, "~> 3.13"},

      # The vault, as a git dependency pinned to a SHA on its main branch.
      # `encryptor` 0.1.0 on Hex is a name reservation: it carries the
      # package's moduledoc and none of the vault API this layer calls, so a
      # version requirement resolves to something that does not export
      # `encrypt/2`. The pin moves to a version requirement at the vault's
      # first real release; until then this is the only dependency form that
      # names the code the types are written against.
      {:encryptor, github: "riddler/encryptor", ref: "ece9647a5b2fdeb4176e349d717bafa2db0e3080"},

      # The serializer `Encryptor.Ecto.Map` defaults to (ADR-0001 decision 8).
      # A direct dependency rather than a transitive one: the vault happens to
      # pull Jason in today, and a default that works only because somebody
      # else's dependency tree supplies it is a default that breaks on an
      # upstream change nobody here reviews. `:json` still takes any module
      # exporting `encode!/1` and `decode!/1`, so a host with its own
      # serializer names it and this one goes unused.
      {:jason, "~> 1.4"},

      # The migration window's `[:encryptor_ecto, :legacy_load]` event
      # (ADR-0004 decision 5). A direct dependency for the same reason Jason
      # above is one: `ecto` happens to pull `telemetry` in today, and a call
      # that works only because somebody else's dependency tree supplies the
      # module is a call that breaks on an upstream change nobody here
      # reviews.
      {:telemetry, "~> 1.0"},

      # Dev / test
      #
      # `ecto_sql` and `postgrex` are test-only. The library's runtime
      # dependencies are `ecto`, the vault, and the JSON serializer above -
      # which is what the README claims, and the reason
      # `Encryptor.Ecto.TestDatabase` probes Postgres with a bare TCP connect
      # rather than a driver handshake. What they buy here is a real
      # repository for the database-backed tests: an `Ecto.Type` that only
      # ever round-trips through a hand-called `dump/3` has not been shown to
      # survive the adapter's own dump and load path.
      {:ecto_sql, "~> 3.13", only: :test},
      {:postgrex, "~> 0.21", only: :test},
      {:ex_quality, "~> 0.14", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
