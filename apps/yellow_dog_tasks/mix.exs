defmodule YellowDog.Tasks.MixProject do
  use Mix.Project

  def project do
    [
      app: :yellow_dog_tasks,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {YellowDog.Tasks.Application, []},
      extra_applications: [:crypto, :logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:geo_ip_db, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:yellow_dog_fingerprint, in_umbrella: true},
      {:yellow_dog_config, in_umbrella: true},
      {:yellow_dog_dns, in_umbrella: true},
      {:yellow_dog_store, in_umbrella: true},
      {:tz, "~> 0.28.2"},
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
