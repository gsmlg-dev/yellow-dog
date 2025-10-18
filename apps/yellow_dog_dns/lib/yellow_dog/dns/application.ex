defmodule YellowDog.Dns.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # DNS View Manager
      {YellowDog.Dns.ViewManager, []},

      # DNS Name Resolver
      {YellowDog.Dns.NameResolver, []}
    ]

    opts = [strategy: :one_for_one, name: YellowDog.Dns.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
