defmodule YellowDog.ManagementCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      YellowDog.Management.ManifestStore,
      YellowDog.Management.EventStore,
      YellowDog.Management.Servers,
      YellowDog.Management.Netmans
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 5,
      name: YellowDog.ManagementCore.Supervisor
    )
  end
end
