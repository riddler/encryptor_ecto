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

  defp package do
    [
      name: "encryptor_ecto",
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md LICENSE),
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  # ex_doc and its `docs/0` configuration, and CI, are added by the beads that
  # follow this one in the bootstrap stack.
  #
  # `encryptor` is not on Hex yet. Until its first release it enters as a git
  # dep pinned to a pushed SHA, which is the committed form - never a path
  # override. Re-pin to `{:encryptor, "~> 0.1"}` at that release.
  defp deps do
    [
      {:ecto, "~> 3.13"},
      {:encryptor, github: "riddler/encryptor", ref: "05bd67c0c4840e363911a2a70f1aa48a448fffd1"},

      # Dev / test
      {:ex_quality, "~> 0.14", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
end
