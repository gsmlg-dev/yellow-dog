defmodule YellowDog.Management.MixProject do
  use Mix.Project

  def project do
    [
      app: :yellow_dog_management,
      version: "0.1.0",
      elixir: "~> 1.18",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      config_path: "config/config.exs",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      start_permanent: Mix.env() == :prod,
      releases: [yellow_dog_management: [include_executables_for: [:unix]]],
      aliases: [
        "ecto.setup": ["ecto.create", "ecto.migrate"],
        test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
      ],
      deps: [
        {:yellow_dog_config_spec, in_umbrella: true},
        {:ecto_sql, "~> 3.14"},
        {:postgrex, "~> 0.22"},
        {:oban, "~> 2.20"},
        {:mint, "~> 1.9"},
        {:bandit, "~> 1.12"},
        {:plug, "~> 1.18"},
        {:jason, "~> 1.4"},
        {:phoenix, "~> 1.8"},
        {:phoenix_pubsub, "~> 2.1"},
        {:phoenix_live_view, "~> 1.2"},
        {:phoenix_html, "~> 4.3"},
        {:phoenix_duskmoon, "~> 9.12"},
        {:gettext, "~> 1.0"},
        {:gsmlg_mac, "~> 0.1.2"},
        {:gsmlg_whois, "~> 0.5.2"},
        {:mmdb2_decoder, "~> 3.0"},
        {:lazy_html, "~> 0.1", only: :test},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
      ]
    ]
  end

  def application do
    [
      mod: {YellowDog.Management.Application, []},
      extra_applications: [:logger, :crypto, :ssl]
    ]
  end
end
