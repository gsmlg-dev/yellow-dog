defmodule YellowDog.MixProject do
  use Mix.Project

  def project do
    [
      app: :yellow_dog,
      version: "1.1.1",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      releases: [
        yellow_dog: [
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
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:burrito, "~> 1.0"}
    ]
  end
end
