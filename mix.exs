defmodule YellowDog.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "1.1.1",
      start_permanent: Mix.env() == :prod,
      name: "YellowDog",
      description: "YellowDog is a Domain Name Server and DHCP Server",
      releases: [
        yellow_dog: [
          include_executables_for: [:unix],
          applications: [
            yellow_dog_core: :permanent,
            yellow_dog_dns: :permanent
          ]
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
      {:abyss, "~> 0.4"},
      {:ex_dns, "~> 0.3"},
      {:dhcp_ex, "~> 0.4"},
      {:telemetry, "~> 1.0"},
      {:toml, "~> 0.7"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
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
      source_url: "https://github.com/gsmlg-dev/YellowDogDNS.git",
      source_ref: "v1.1.1"
    ]
  end

  defp aliases do
    [
      publish: [
        "format",
        "hex.publish --yes"
      ]
    ]
  end
end
