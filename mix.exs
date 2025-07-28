defmodule YellowDog.MixProject do
  use Mix.Project

  @version "1.1.1"
  @source_url "https://github.com/gsmlg-dev/YellowDogDNS.git"

  def project do
    [
      app: :yellow_dog,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      name: "YellowDog",
      description: "YellowDog is a Domain Name Server and DHCP Server",
      releases: [
        yellow_dog: [
          include_executables_for: [:unix],
          applications: [yellow_dog: :permanent]
        ],
        yellow_dog_standalone: [
          steps: [:assemble, &Burrito.wrap/1],
          burrito: [
            targets: [
              linux_arm64: [os: :linux, cpu: :aarch64],
              linux_amd64: [os: :linux, cpu: :x86_64]
            ]
          ]
        ]
      ],
      dialyzer: dialyzer(),
      aliases: aliases(),
      docs: docs(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # mod: {YellowDog, []},
      extra_applications: [:logger, :ssl]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:abyss, "~> 0.4"},
      {:ex_dns, "~> 0.3"},
      {:dhcp_ex, "~> 0.4"},
      {:telemetry, "~> 1.0"},
      {:toml, "~> 0.7"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:burrito, "~> 1.0"}
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
      source_url: @source_url,
      source_ref: "v#{@version}"
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
