defmodule Mix.Tasks.StartServer do
  @shortdoc "Starts the DNS server with the dashboard web console"

  @moduledoc """
  Starts the DNS server along with the Phoenix web console (dashboard).

  This task starts all server applications in the umbrella, including the Phoenix
  web console. It automatically configures Phoenix to serve endpoints.

  Use this task to run the server with the dashboard:

      $ mix start_server

  To start the server inside an interactive shell:

      $ iex -S mix start_server
  """

  use Mix.Task

  @impl true
  def run(args) do
    # Ensure Phoenix endpoints are served
    Application.put_env(:phoenix, :serve_endpoints, true)

    # Run the umbrella applications without halting unless running in IEx
    Mix.Tasks.Run.run(run_args() ++ args)
  end

  defp run_args do
    if iex_running?(), do: [], else: ["--no-halt"]
  end

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
