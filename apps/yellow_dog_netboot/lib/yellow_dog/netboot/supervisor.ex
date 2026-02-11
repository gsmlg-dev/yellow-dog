defmodule YellowDog.Netboot.Supervisor do
  @moduledoc """
  Top-level supervisor for the netboot subsystem.

  Starts TFTP server, device registry, manifest store, script engine,
  and asset store in dependency order.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Application.get_env(:yellow_dog_netboot, :config, %{})

    children = [
      {YellowDog.Netboot.Asset.Store, config: config},
      {YellowDog.Netboot.Manifest.Store, config: config},
      {YellowDog.Netboot.Boot.ScriptEngine, config: config},
      {YellowDog.Netboot.Device.Registry, config: config},
      {YellowDog.Netboot.TFTP.TransferSupervisor, []},
      {YellowDog.Netboot.TFTP.Server, config: config}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
