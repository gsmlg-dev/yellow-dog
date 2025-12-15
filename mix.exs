defmodule YellowDog.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "1.1.1",
      start_permanent: Mix.env() == :prod,
      description: "YellowDog is a Domain Name Server and DHCP Server",
      releases: [
        yellow_dog: [
          include_executables_for: [:unix],
          applications: [
            yellow_dog: :permanent,
            yellow_dog_dns: :permanent,
            yellow_dog_telemetry: :permanent
          ]
        ]
      ],
      dialyzer: dialyzer(),
      aliases: aliases(),
      docs: docs(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
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
      source_ref: "v1.1.1"
    ]
  end

  defp aliases do
    [
      test: ["cmd mix test"],
      lint: ["cmd mix lint"],
      credo: ["cmd mix credo --strict"],
      dialyzer: ["cmd mix dialyzer"],
      # E2E test aliases
      "test.e2e": ["test e2e_test/"],
      "test.e2e.dns": ["test e2e_test/dns_e2e_test.exs"],
      "test.e2e.mdns": ["test e2e_test/mdns_e2e_test.exs"],
      "test.e2e.dhcpv4": ["test e2e_test/dhcpv4_e2e_test.exs"],
      "test.e2e.dhcpv6": ["test e2e_test/dhcpv6_e2e_test.exs"]
    ]
  end
end
