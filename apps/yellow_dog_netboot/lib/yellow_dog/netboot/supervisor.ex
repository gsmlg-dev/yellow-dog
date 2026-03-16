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
    # Register netboot boot options callback with DHCPv4 handler.
    # This injects Option 66/67 (TFTP server/bootfile) during OFFER/ACK
    # when a device has a netboot profile assigned.
    Application.put_env(
      :yellow_dog_dhcpv4,
      :boot_options_fn,
      {YellowDog.Netboot.Boot.Profile, :for_device}
    )

    # Bridge TFTP telemetry events to PubSub for console Boot Log
    YellowDog.Netboot.TelemetryHandler.attach()

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
