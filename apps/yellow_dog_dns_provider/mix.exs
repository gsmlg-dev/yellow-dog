defmodule YellowDog.DnsProvider.MixProject do
  use Mix.Project

  def project do
    [
      app: :yellow_dog_dns_provider,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.2"},
      {:yellow_dog, in_umbrella: true},
      {:yellow_dog_dns, in_umbrella: true},
      {:yellow_dog_store, in_umbrella: true},
      {:yellow_dog_telemetry, in_umbrella: true},
      {:stream_data, "~> 1.0", only: [:test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [lint: ["credo --strict", "dialyzer"]]
  end
end
