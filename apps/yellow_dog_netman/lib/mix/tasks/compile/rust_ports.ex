defmodule Mix.Tasks.Compile.RustPorts do
  @moduledoc """
  Mix compiler task that builds the Rust netlink_helper port binary.

  Invoked automatically by Mix when `compilers: [:rust_ports | Mix.compilers()]`
  is added to `mix.exs`. Builds the `native/netlink_helper` Cargo project and
  copies the resulting binary to `priv/native/netlink_helper`.

  ## Behaviour

  - If `cargo` is not found on PATH, emits a warning and skips the build.
    The Elixir application will run in degraded mode (no real netlink events).
  - If `cargo` is found, runs `cargo build --release` in the native directory.
  - The built binary is copied to `priv/native/` (creating the directory if needed).
  - On `mix clean`, the binary in `priv/native/` is removed.

  ## Requirements

  - Rust toolchain (cargo) on PATH
  - Linux host (netlink is Linux-specific)

  ## Adding to mix.exs

      def project do
        [
          ...
          compilers: [:rust_ports | Mix.compilers()],
          ...
        ]
      end
  """

  use Mix.Task.Compiler

  @native_dir "native/netlink_helper"
  @binary_name "netlink_helper"
  @output_dir "priv/native"

  @impl true
  def run(_args) do
    app_dir = File.cwd!()
    native_dir = Path.join(app_dir, @native_dir)
    output_dir = Path.join(app_dir, @output_dir)
    output_binary = Path.join(output_dir, @binary_name)

    if not File.dir?(native_dir) do
      Mix.shell().info("RustPorts: native directory not found, skipping build")
      {:ok, []}
    else
      case System.find_executable("cargo") do
        nil ->
          Mix.shell().info(
            "RustPorts: cargo not found on PATH, skipping Rust build. " <>
              "The application will run in degraded mode without netlink integration."
          )

          {:ok, []}

        cargo ->
          build_rust_binary(cargo, native_dir, output_dir, output_binary)
      end
    end
  end

  @impl true
  def clean do
    app_dir = File.cwd!()
    output_binary = Path.join([app_dir, @output_dir, @binary_name])

    if File.exists?(output_binary) do
      File.rm!(output_binary)
      Mix.shell().info("RustPorts: removed #{output_binary}")
    end

    :ok
  end

  defp build_rust_binary(cargo, native_dir, output_dir, output_binary) do
    Mix.shell().info("RustPorts: building netlink_helper...")

    result =
      System.cmd(
        cargo,
        ["build", "--release", "--quiet"],
        cd: native_dir,
        stderr_to_stdout: true,
        env: rust_env()
      )

    case result do
      {_output, 0} ->
        # Locate the built binary
        built_binary = Path.join([native_dir, "target", "release", @binary_name])

        if File.exists?(built_binary) do
          File.mkdir_p!(output_dir)
          File.copy!(built_binary, output_binary)
          File.chmod!(output_binary, 0o755)
          Mix.shell().info("RustPorts: installed #{output_binary}")
          {:ok, []}
        else
          diagnostic = %Mix.Task.Compiler.Diagnostic{
            compiler_name: "rust_ports",
            file: Path.join(native_dir, "src/main.rs"),
            position: nil,
            message: "cargo build succeeded but binary not found at #{built_binary}",
            severity: :error
          }

          {:error, [diagnostic]}
        end

      {output, exit_code} ->
        Mix.shell().error("RustPorts: cargo build failed (exit #{exit_code}):\n#{output}")

        diagnostic = %Mix.Task.Compiler.Diagnostic{
          compiler_name: "rust_ports",
          file: Path.join(native_dir, "Cargo.toml"),
          position: nil,
          message: "cargo build failed with exit code #{exit_code}",
          severity: :error
        }

        {:error, [diagnostic]}
    end
  end

  defp rust_env do
    # Pass through relevant environment variables for cross-compilation
    base_env = [{"CARGO_TERM_COLOR", "never"}]

    case System.get_env("CARGO_TARGET_DIR") do
      nil -> base_env
      target -> [{"CARGO_TARGET_DIR", target} | base_env]
    end
  end
end
