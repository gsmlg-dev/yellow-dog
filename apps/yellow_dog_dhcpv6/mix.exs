defmodule YellowDog.Dhcpv6.MixProject do
  use Mix.Project

  def project do
    [
      app: :yellow_dog_dhcpv6,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {YellowDog.Dhcpv6.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # External dependencies for DHCPv6 functionality
      {:dhcp_ex, "~> 0.4"},
      {:abyss, "~> 0.4"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
