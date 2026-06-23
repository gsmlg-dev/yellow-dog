defmodule YellowDog.DnsProvider.Supervisor do
  @moduledoc """
  Top-level supervisor for the DNS provider subsystem.

  Children (in start order):
  1. Registry — unique name registration for SyncEngines
  2. ConflictStore — ETS cache for sync conflicts
  3. SyncSupervisor — DynamicSupervisor for SyncEngine processes
  4. ConfigWatcher — EventBridge consumer for config changes
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: YellowDog.DnsProvider.Registry},
      YellowDog.DnsProvider.ConflictStore,
      YellowDog.DnsProvider.SyncSupervisor,
      YellowDog.DnsProvider.ConfigWatcher
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
