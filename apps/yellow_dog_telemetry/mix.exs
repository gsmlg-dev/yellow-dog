defmodule YellowDog.Telemetry.MixProject do
  use Mix.Project

  def project do
    [
      app: :yellow_dog_telemetry,
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

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {YellowDog.Telemetry.Application, []},
      extra_applications: [:logger, :telemetry]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Core telemetry dependency
      {:telemetry, "~> 1.2"},

      # JSON encoding for production logs
      {:jason, "~> 1.4", optional: true},

      # Development and test dependencies
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
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