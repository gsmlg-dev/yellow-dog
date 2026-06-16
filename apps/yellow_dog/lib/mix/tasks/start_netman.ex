defmodule Mix.Tasks.StartNetman do
  @shortdoc "Starts the Netman network manager service only"

  @moduledoc """
  Starts the Netman network manager service only, disabling server-side services.

  This task enables Netman autostart at runtime (overriding any configuration that
  disables it), disables all server-side services, and runs the application tree
  without halting.

  Use this task to run only the Netman service:

      $ mix start_netman

  To start the Netman service inside an interactive shell:

      $ iex -S mix start_netman
  """

  use Mix.Task

  @impl true
  def run(args) do
    # Force Netman to autostart
    Application.put_env(:yellow_dog_netman, :netman_autostart, true)

    # Force netman-only mode in the core application (disabling DNS, DHCP, mDNS, etc.)
    Application.put_env(:yellow_dog, :netman_only, true)

    # Run the applications without halting unless running in IEx
    Mix.Tasks.Run.run(run_args() ++ args)
  end

  defp run_args do
    if iex_running?(), do: [], else: ["--no-halt"]
  end

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
