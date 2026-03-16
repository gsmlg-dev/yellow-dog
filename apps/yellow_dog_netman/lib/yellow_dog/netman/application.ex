defmodule YellowDog.Netman.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {YellowDog.Resolved.Supervisor, []},
      {YellowDog.Netman.Supervisor, []}
    ]

    opts = [strategy: :one_for_one, name: YellowDog.Netman.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
