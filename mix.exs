defmodule YellowDog.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "1.1.1",
      start_permanent: Mix.env() == :prod,
      description: "YellowDog DNS/DHCP server and network manager",
      releases: [
        yellow_dog_server: [
          include_executables_for: [:unix],
          applications: [
            yellow_dog: :permanent,
            yellow_dog_telemetry: :permanent,
            yellow_dog_dns: :permanent,
            yellow_dog_mdns: :permanent,
            yellow_dog_dhcpv4: :permanent,
            yellow_dog_dhcpv6: :permanent,
            yellow_dog_netboot: :permanent,
            yellow_dog_identity: :permanent,
            yellow_dog_fingerprint: :permanent,
            yellow_dog_console: :permanent
          ]
        ],
        yellow_dog_netman: [
          include_executables_for: [:unix],
          applications: [
            yellow_dog: :permanent,
            yellow_dog_telemetry: :permanent,
            yellow_dog_dhcp_client: :permanent,
            yellow_dog_mdns: :permanent,
            yellow_dog_netman: :permanent
          ]
        ],
        yellow_dog: [
          include_executables_for: [:unix],
          applications: [
            yellow_dog: :permanent,
            yellow_dog_telemetry: :permanent,
            yellow_dog_dns: :permanent,
            yellow_dog_mdns: :permanent,
            yellow_dog_dhcpv4: :permanent,
            yellow_dog_dhcpv6: :permanent,
            yellow_dog_dhcp_client: :permanent,
            yellow_dog_netman: :permanent,
            yellow_dog_netboot: :permanent,
            yellow_dog_identity: :permanent,
            yellow_dog_fingerprint: :permanent,
            yellow_dog_console: :permanent
          ]
        ]
      ],
      dialyzer: dialyzer(),
      aliases: aliases(),
      docs: docs(),
      deps: deps()
    ] ++ phoenix_listeners()
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

  defp phoenix_listeners do
    if Mix.env() in [:dev, :test] do
      [listeners: [Phoenix.CodeReloader]]
    else
      []
    end
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
      # E2E test aliases - use function to run tests at umbrella root
      "test.e2e": &run_e2e_tests/1,
      "test.e2e.dns": &run_e2e_dns/1,
      "test.e2e.mdns": &run_e2e_mdns/1,
      "test.e2e.dhcpv4": &run_e2e_dhcpv4/1,
      "test.e2e.dhcpv6": &run_e2e_dhcpv6/1,
      "test.e2e.netboot": &run_e2e_netboot/1
    ]
  end

  # E2E test functions - run ExUnit directly at umbrella level
  defp run_e2e_tests(_args) do
    run_e2e_test_files(["e2e_test/"])
  end

  defp run_e2e_dns(_args) do
    files = Path.wildcard("e2e_test/dns*_e2e_test.exs")
    run_e2e_test_files(files)
  end

  defp run_e2e_mdns(_args) do
    run_e2e_test_files(["e2e_test/mdns_e2e_test.exs"])
  end

  defp run_e2e_dhcpv4(_args) do
    run_e2e_test_files(["e2e_test/dhcpv4_e2e_test.exs"])
  end

  defp run_e2e_dhcpv6(_args) do
    run_e2e_test_files(["e2e_test/dhcpv6_e2e_test.exs"])
  end

  defp run_e2e_netboot(_args) do
    run_e2e_test_files(["e2e_test/netboot_tftp_e2e_test.exs"])
  end

  defp run_e2e_test_files(paths) do
    # Ensure test environment
    Mix.env(:test)

    # Compile the umbrella apps first (skip compile env validation for E2E)
    Mix.Task.run("compile", ["--no-validate-compile-env"])

    # Load and compile test helper
    Code.compile_file("e2e_test/test_helper.exs")

    # Require all test files
    Enum.each(paths, fn path ->
      if File.dir?(path) do
        Path.wildcard(Path.join(path, "**/*_test.exs"))
        |> Enum.each(&Code.require_file/1)
      else
        if File.exists?(path) do
          Code.require_file(path)
        end
      end
    end)

    # Run ExUnit and check results
    %{failures: failures, excluded: excluded, total: total} = ExUnit.run()

    # Exit with non-zero code if there are failures
    if failures > 0 do
      Mix.raise("#{failures} test(s) failed out of #{total} (#{excluded} excluded)")
    end

    :ok
  end
end
