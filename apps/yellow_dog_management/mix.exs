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
        {:styx, "~> 0.2"},
        {:http_fetch, "~> 1.0.0-rc.20"},
        {:gaoxy_http, "~> 0.16"},
        {:websock_adapter, "~> 0.16", hex: :gaoxy_websock_adapter, override: true},
        {:plug, "~> 1.18"},
        {:jason, "~> 1.4"},
        {:jose, "~> 1.11"},
        {:jsv, "~> 0.26"},
        {:phoenix, "~> 1.8"},
        {:phoenix_pubsub, "~> 2.1"},
        {:phoenix_live_view, "~> 1.2"},
        {:phoenix_html, "~> 4.3"},
        {:phoenix_duskmoon, "~> 10.1"},
        {:gettext, "~> 1.0"},
        {:yellow_dog_mac, in_umbrella: true},
        {:yellow_dog_whois, in_umbrella: true},
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
