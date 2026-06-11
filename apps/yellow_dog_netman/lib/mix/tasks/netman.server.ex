defmodule Mix.Tasks.Netman.Server do
  @shortdoc "Starts the Netman network manager daemon"

  @moduledoc """
  Starts the Netman network manager daemon.

  This task enables Netman autostart at runtime (overriding any config that
  disables it) and then runs the application tree without halting, similar to
  how `mix phx.server` works for Phoenix applications.

  Use this task to run only the Netman daemon without starting the Phoenix
  web console:

      $ mix netman.server

  To start both the web console and Netman, run each in a separate terminal:

      # Terminal 1 — web console only
      $ mix phx.server

      # Terminal 2 — netman daemon only
      $ mix netman.server

  ## Configuration

  Netman autostart is controlled by the `:netman_autostart` key in the
  `:yellow_dog_netman` application config. It defaults to `true` but is set
  to `false` in `config/dev.exs` to prevent it from starting when running
  `mix phx.server`. This task overrides that setting at runtime.
  """

  use Mix.Task

  @impl true
  def run(args) do
    # Enable Netman autostart — overrides the `netman_autostart: false` in dev.exs
    # so that the full Netman supervisor tree is started regardless of config.
    Application.put_env(:yellow_dog_netman, :netman_autostart, true)

    Mix.Tasks.Run.run(run_args() ++ args)
  end

  defp run_args do
    if iex_running?(), do: [], else: ["--no-halt"]
  end

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
