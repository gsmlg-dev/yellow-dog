defmodule YellowDogIdentity.MixProject do
  use Mix.Project

  def project do
    [
      app: :yellow_dog_identity,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :inets]
    ]
  end

  defp deps do
    [
      # Core dependencies
      {:yellow_dog, in_umbrella: true},
      {:yellow_dog_store, in_umbrella: true},
      {:yellow_dog_telemetry, in_umbrella: true},

      # TOML persistence
      {:telemetry, "~> 1.0"},
      {:toml, "~> 0.7"},

      # PubSub broadcasting to Console LiveViews
      {:phoenix_pubsub, "~> 2.1"},

      # JWT verification (GCP OIDC tokens)
      {:jose, "~> 1.11"},

      # X.509 certificate handling (AWS PKCS7, Azure cert chain)
      {:x509, "~> 0.9"},

      # Development and test dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      lint: ["credo --strict", "dialyzer"]
    ]
  end
end
