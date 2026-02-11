defmodule YellowDog.Netboot.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {YellowDog.Netboot.Supervisor, []}
    ]

    opts = [strategy: :one_for_one, name: YellowDog.Netboot.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
