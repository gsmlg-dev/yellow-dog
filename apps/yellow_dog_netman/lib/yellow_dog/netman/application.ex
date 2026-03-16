defmodule YellowDog.Netman.Application do
  @moduledoc false
  use Application

  require Logger

  @compile_env Mix.env()

  @impl true
  def start(_type, _args) do
    children =
      resolved_child() ++
        [
          {YellowDog.Netman.Supervisor, []}
        ]

    opts = [strategy: :one_for_one, name: YellowDog.Netman.AppSupervisor]
    Supervisor.start_link(children, opts)
  end

  # Resolved is a client-side stub resolver that binds port 53.
  # Only start in prod (requires privileged port); skip in dev/test.
  if @compile_env == :prod do
    defp resolved_child do
      if Code.ensure_loaded?(YellowDog.Resolved.Supervisor) do
        [{YellowDog.Resolved.Supervisor, []}]
      else
        []
      end
    end
  else
    defp resolved_child, do: []
  end
end
