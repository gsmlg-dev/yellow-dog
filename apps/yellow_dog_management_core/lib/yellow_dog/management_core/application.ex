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
      name: YellowDog.ManagementCore.Supervisor
    )
  end
end
