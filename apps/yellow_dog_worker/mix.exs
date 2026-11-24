defmodule YellowDog.Worker.MixProject do
  use Mix.Project

  def project do
    [
      app: :yellow_dog_worker,
      version: "0.1.0",
      elixir: "~> 1.18",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      config_path: "config/config.exs",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: [yellow_dog_worker: [include_executables_for: [:unix]]],
      deps: [
        {:yellow_dog_config_spec, in_umbrella: true},
        {:abyss, "~> 1.0.0-rc.20"},
        {:elixir_quic, "~> 1.0.0-rc.20"},
        {:ex_dns, in_umbrella: true},
        {:jason, "~> 1.4"},
        {:phoenix_socket_client, "~> 0.9.1"},
        {:toml, "~> 0.7"},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
      ]
    ]
  end

  def application do
    [
      mod: {YellowDog.Worker.Application, []},
      extra_applications: [:logger, :crypto, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
