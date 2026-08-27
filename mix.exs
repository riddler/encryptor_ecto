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
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  # `encryptor` is not on Hex yet. Until its first release it enters as a git
  # dep pinned to a pushed SHA, which is the committed form - never a path
  # override. Re-pin to `{:encryptor, "~> 0.1"}` at that release.
  #
  # One consequence, since it is not obvious from anything else here: a git
  # dependency cannot be published, so `mix hex.build` stops with
  # "Dependencies excluded from the package (only Hex packages can be
  # dependencies): encryptor" until the re-pin. That is expected, not a
  # defect - the package() metadata above is complete and correct, and this
  # package is not publishable before the vault is anyway. CI does not run
  # hex.build, so nothing in the gate depends on it.
  defp deps do
    [
      {:ecto, "~> 3.13"},
      {:encryptor, github: "riddler/encryptor", ref: "05bd67c0c4840e363911a2a70f1aa48a448fffd1"},

      # Dev / test
      {:ex_quality, "~> 0.14", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
