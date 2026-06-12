defmodule YellowDog.Store.MixProject do
  use Mix.Project

  def project do
    [
      app: :yellow_dog_store,
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
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # In-umbrella dependencies
      {:yellow_dog_config, in_umbrella: true},
      {:yellow_dog_telemetry, in_umbrella: true},

      # External dependencies
      {:telemetry, "~> 1.0"},
      {:toml, "~> 0.7"},
      {:concord, "~> 2.1"},
      {:gen_stage, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6 or ~> 1.0", override: true},

      # Development and test dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:test]}
    ]
  end

  defp aliases do
    [
      lint: ["credo --strict", "dialyzer"]
    ]
  end
end
