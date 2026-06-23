defmodule YellowDog.DnsProvider.SyncSupervisor do
  @moduledoc """
  DynamicSupervisor for SyncEngine processes.

  Each configured DNS provider gets its own SyncEngine child, started
  and stopped dynamically as providers are added, removed, or toggled.
  """

  use DynamicSupervisor

  alias YellowDog.DnsProvider.SyncEngine

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a SyncEngine for the given provider config and module."
  @spec start_engine(YellowDog.DnsProvider.Config.t(), module()) ::
          DynamicSupervisor.on_start_child()
  def start_engine(config, provider_module) do
    spec = {SyncEngine, config: config, provider_module: provider_module}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc "Stop the SyncEngine for the named provider."
  @spec stop_engine(String.t()) :: :ok | {:error, :not_found}
  def stop_engine(provider_name) do
    case Registry.lookup(YellowDog.DnsProvider.Registry, provider_name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end
end
