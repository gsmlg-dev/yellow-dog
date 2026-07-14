defmodule YellowDog.Netman.MixProject do
  use Mix.Project

  def project do
    [
      app: :yellow_dog_netman,
      version: "0.1.0",
      description:
        "Network manager for wired ethernet with DHCP/static IP, reconciliation engine, and netlink integration",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      compilers: Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_coverage: [
        threshold: 90,
        ignore_modules: [
          # Requires Rust toolchain — not testable in CI without native build
          Mix.Tasks.Compile.RustPorts,
          # Test support helper — not production code
          YellowDog.Netman.Test.MockNetlink,
          # Rust port communication paths — untestable without the native binary
          YellowDog.Netman.Kernel.Netlink
        ]
      ]
    ]
  end

  def application do
    [
      mod: {YellowDog.Netman.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:yellow_dog_config, in_umbrella: true},
      {:yellow_dog_telemetry, in_umbrella: true},
      {:yellow_dog_dhcp_client, in_umbrella: true},
      {:yellow_dog_resolved, in_umbrella: true},
      {:ex_dhcp, in_umbrella: true},
      {:yellow_dog_netman_agent, in_umbrella: true, only: [:test], runtime: false},
      {:phoenix_socket_client, "~> 0.7.0"},
      {:telemetry, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:toml, "~> 0.7"},
      {:file_system, "~> 1.0"},
      {:stream_data, "~> 1.0", only: [:test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "build.native": ["compile.rust_ports"],
      lint: ["credo --strict", "dialyzer"]
    ]
  end
end
