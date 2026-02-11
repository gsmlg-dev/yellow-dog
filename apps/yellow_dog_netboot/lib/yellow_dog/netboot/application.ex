defmodule YellowDog.Netboot.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
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

    children = [
      {YellowDog.Netboot.Supervisor, []}
    ]

    opts = [strategy: :one_for_one, name: YellowDog.Netboot.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
