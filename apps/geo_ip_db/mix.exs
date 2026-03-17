defmodule GeoIpDb.MixProject do
  use Mix.Project

  @source_url "https://github.com/gsmlg-dev/yellow-dog"
  @version "0.0.0"

  def project do
    [
      app: :geo_ip_db,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      name: "GeoIpDb",
      description: "IP geolocation database using MMDB format (MaxMind/DB-IP)",
      source_url: @source_url,
      dialyzer: dialyzer(),
      aliases: aliases(),
      package: package(),
      deps: deps(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps() do
    [
      {:mmdb2_decoder, "~> 3.0"},
      {:http_fetch, "~> 0.8", runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7.13", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
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

  defp package do
    [
      maintainers: ["Jonathan Gao"],
      licenses: ["MIT"],
      files: ~w(lib priv LICENSE mix.exs README.md),
      links: %{
        Github: @source_url,
        Changelog: "https://hexdocs.pm/geo_ip_db/changelog.html"
      }
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
      lint: ["credo --strict", "dialyzer"]
    ]
  end
end
