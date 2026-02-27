defmodule YellowDog.Netman.Supervisor do
  @moduledoc """
  Top-level supervisor for the Network Manager.

  Uses `rest_for_one` strategy — if a foundational subsystem crashes,
  all dependent subsystems above it restart in order.

  Start order:
  1. Kernel.Supervisor (netlink, link/address/route monitors)
  2. EventBus (Registry-based PubSub)
  3. ProfileStore (TOML profile management)
  4. Connection.Supervisor (DynamicSupervisor for per-interface FSMs)
  5. ReconciliationEngine (desired-state reconciliation loop)
  6. API.Supervisor (Unix socket CLI interface)
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: YellowDog.Netman.Registry},
      {YellowDog.Netman.Kernel.Supervisor, []},
      {YellowDog.Netman.EventBus, []},
      {YellowDog.Netman.ProfileStore, []},
      {YellowDog.Netman.Connection.Supervisor, []},
      {YellowDog.Netman.ReconciliationEngine, []},
      {YellowDog.Netman.API.Supervisor, []}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
