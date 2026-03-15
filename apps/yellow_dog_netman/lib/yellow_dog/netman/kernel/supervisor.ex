defmodule YellowDog.Netman.Kernel.Supervisor do
  @moduledoc """
  Supervisor for the kernel subsystem.

  Starts netlink port, then monitors for links, addresses, routes,
  rules, and neighbors.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {YellowDog.Netman.Kernel.Netlink, []},
      {YellowDog.Netman.Kernel.LinkMonitor, []},
      {YellowDog.Netman.Kernel.AddressManager, []},
      {YellowDog.Netman.Kernel.RouteManager, []},
      {YellowDog.Netman.Kernel.RuleManager, []},
      {YellowDog.Netman.Kernel.NeighborMonitor, []}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
