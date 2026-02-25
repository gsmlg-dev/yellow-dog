defmodule YellowDog.DhcpClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :yellow_dog_dhcp_client,
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
      extra_applications: [:logger],
      mod: {YellowDog.DhcpClient.Application, []}
    ]
  end

  defp deps do
    [
      {:yellow_dog, in_umbrella: true},
      {:yellow_dog_telemetry, in_umbrella: true},
      {:ex_dhcp, in_umbrella: true},
      {:telemetry, "~> 1.0"},
      {:file_system, "~> 1.0"},
      {:toml, "~> 0.7"},
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
