defmodule YellowDog.ServerAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :yellow_dog_server_agent,
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
      mod: {YellowDog.ServerAgent.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:yellow_dog_sync, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:phoenix_socket_client, "~> 0.8.2"},
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
