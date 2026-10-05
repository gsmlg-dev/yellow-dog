defmodule YellowDog.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "1.2.0",
      start_permanent: Mix.env() == :prod,
      description: "Independent YellowDog Management and TOML-driven Worker",
      apps: [:yellow_dog_config_spec, :yellow_dog_management, :yellow_dog_worker, :abyss, :ex_dns],
      releases: [
        yellow_dog_management: [
          include_executables_for: [:unix],
          rel_templates_path: "rel/phase1",
          runtime_config_path: "apps/yellow_dog_management/config/runtime.exs",
          applications: [yellow_dog_management: :permanent]
        ],
        yellow_dog_worker: [
          include_executables_for: [:unix],
          rel_templates_path: "rel/phase1",
          runtime_config_path: "apps/yellow_dog_worker/config/runtime.exs",
          applications: [yellow_dog_worker: :permanent]
        ]
      ],
      dialyzer: dialyzer(),
      aliases: aliases(),
      docs: docs(),
      deps: deps()
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    [
      # Shared dependencies for all apps
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 0.6 or ~> 1.0", override: true},
      {:toml, "~> 0.7"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_core_path: "priv/plts",
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_deps: :apps_direct,
      plt_add_apps: [:public_key],
      flags: [
        "-Werror_handling",
        "-Wextra_return",
        "-Wmissing_return",
        "-Wunknown",
        "-Wunmatched_returns",
        "-Wunderspecs"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_url: "https://github.com/gsmlg-app/yellow-dog.git",
      source_ref: "v1.1.2"
    ]
  end

  defp aliases do
    [
      test: ["cmd mix test"],
      lint: ["cmd mix lint"],
      credo: ["cmd mix credo --strict"],
      dialyzer: ["cmd mix dialyzer"],
      "ecto.setup": ["do --app yellow_dog_management cmd mix ecto.setup"],
      "management.run": ["do --app yellow_dog_management cmd mix run --no-halt"],
      "worker.run": ["cmd --app yellow_dog_worker mix run --no-halt"]
    ]
  end
end
