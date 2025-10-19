defmodule YellowDog.Mdns.MixProject do
  use Mix.Project

  def project do
    [
      app: :yellow_dog_mdns,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Core dependencies
      {:yellow_dog_telemetry, in_umbrella: true},
      {:toml, "~> 0.7"},

      # External dependencies for mDNS functionality
      {:ex_dns, in_umbrella: true},
      {:abyss, in_umbrella: true},
      {:telemetry, "~> 1.0"}
    ]
  end
end
