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
      releases: [yellow_dog_worker: [include_executables_for: [:unix]]],
      deps: [
        {:yellow_dog_config_spec, in_umbrella: true},
        {:abyss, in_umbrella: true},
        {:ex_dns, in_umbrella: true},
        {:jason, "~> 1.4"},
        {:toml, "== 0.7.0"}
      ]
    ]
  end

  def application do
    [mod: {YellowDog.Worker.Application, []}, extra_applications: [:logger, :crypto]]
  end
end
