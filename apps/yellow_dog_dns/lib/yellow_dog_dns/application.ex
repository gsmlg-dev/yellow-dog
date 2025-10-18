defmodule YellowDogDns.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # DNS View Manager
      {YellowDogDns.ViewManager, []},

      # DNS Name Resolver
      {YellowDogDns.NameResolver, []}
    ]

    opts = [strategy: :one_for_one, name: YellowDogDns.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
