defmodule YellowDog.Console.MixProject do
  use Mix.Project

  def project do
    [
      app: :yellow_dog_console,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {YellowDog.Console.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:duskmoon_bundler_runtime, "~> 9.7"},
      {:duskmoon_bundler, "~> 9.7", runtime: Mix.env() == :dev},
      {:phoenix_duskmoon, "~> 9.7"},
      {:hackney, "~> 4.0"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 0.6 or ~> 1.0", override: true},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:gettext, "~> 1.0"},
      {:ecto, "~> 3.12"},
      {:phoenix_ecto, "~> 4.6"},
      {:toml, "~> 0.7"},

      # YellowDog dependencies
      {:yellow_dog_management_core, in_umbrella: true},
      {:yellow_dog, in_umbrella: true},
      {:yellow_dog_store, in_umbrella: true},
      {:yellow_dog_mdns, in_umbrella: true},
      {:yellow_dog_dhcpv4, in_umbrella: true},
      {:yellow_dog_dhcpv6, in_umbrella: true},
      {:yellow_dog_dns, in_umbrella: true},
      {:yellow_dog_tasks, in_umbrella: true},
      {:geo_ip_db, in_umbrella: true},
      {:yellow_dog_fingerprint, in_umbrella: true},
      {:yellow_dog_netboot, in_umbrella: true},
      {:yellow_dog_identity, in_umbrella: true},
      {:yellow_dog_dns_provider, in_umbrella: true},
      {:yellow_dog_dhcp_client, in_umbrella: true},
      {:yellow_dog_netman, in_umbrella: true},
      {:gsmlg_whois, "~> 0.5"},
      {:gsmlg_mac, "~> 0.1"},

      # Development and test dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp aliases do
    [
      lint: ["credo --strict", "dialyzer"],
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["npm.install"],
      "assets.build": ["compile", "duskmoon_bundler.build yellow_dog_console --tailwind"],
      "assets.deploy": [
        "duskmoon_bundler.build yellow_dog_console --tailwind --minify",
        "phx.digest"
      ],
      precommit: ["compile --warning-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
