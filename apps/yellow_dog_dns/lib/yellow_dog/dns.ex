defmodule YellowDog.Dns do
  @moduledoc """
  DNS supervisor that manages DNS functionality including name resolution, zones, and views.
  """

  use Supervisor

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children = [
      # DNS View Manager
      {YellowDog.Dns.ViewManager, []},

      # DNS Name Resolver
      {YellowDog.Dns.NameResolver, []}
    ]

    opts = [strategy: :one_for_one]
    Supervisor.init(children, opts)
  end
end
