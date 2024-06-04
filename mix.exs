defmodule YellowDog.MixProject do
  use Mix.Project

  def project do
    [
      app: :yellow_dog,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      releases: [
        yellow_dog: [
          applications: [yellow_dog: :permanent]
        ]
      ],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {YellowDog, []},
      extra_applications: [:logger, :ssl]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:toml, "~> 0.7"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
