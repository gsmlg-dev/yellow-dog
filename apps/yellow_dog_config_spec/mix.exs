defmodule YellowDog.ConfigSpec.MixProject do
  use Mix.Project

  def project do
    [
      app: :yellow_dog_config_spec,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:crypto]]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:toml, "== 0.7.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
