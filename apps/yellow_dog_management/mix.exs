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
      deps: [
        {:yellow_dog_config_spec, path: "../yellow_dog_config_spec"},
        {:ecto_sql, "~> 3.14"},
        {:postgrex, "~> 0.22"},
        {:bandit, "~> 1.12"},
        {:plug, "~> 1.18"},
        {:jason, "~> 1.4"}
      ]
    ]
  end

  def application do
    [mod: {YellowDog.Management.Application, []}, extra_applications: [:logger, :crypto]]
  end
end
