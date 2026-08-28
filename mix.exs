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

      # Dev / test
      #
      # `ecto_sql` and `postgrex` are test-only. The library depends on `ecto`
      # and the vault and nothing else (the package's own claim, and the
      # reason `Encryptor.Ecto.TestDatabase` probes Postgres with a bare TCP
      # connect rather than a driver handshake). What they buy here is a real
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
