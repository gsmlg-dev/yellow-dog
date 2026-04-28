defmodule YellowDog.Netboot.Supervisor do
  @moduledoc """
  Top-level supervisor for the netboot subsystem.

  Starts TFTP server, device registry, manifest store, script engine,
  and asset store in dependency order.
  """

  use Supervisor

  def start_link(opts) do
    opts = Map.new(opts)
    name = Map.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def init(opts) do
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

    config = config_from_opts(opts)

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

  defp config_from_opts(opts) do
    opts = Map.new(opts)

    opts
    |> Map.get(
      :config,
      Map.get(opts, :server_options, Application.get_env(:yellow_dog_netboot, :config, %{}))
    )
    |> normalize_config()
  end

  defp normalize_config(config) when is_list(config) do
    config
    |> Map.new()
    |> normalize_config()
  end

  defp normalize_config(config) when is_map(config) do
    config
    |> put_config_pair(:tftp_port, "tftp_port")
    |> put_config_pair(:tftp_root, "tftp_root")
    |> put_config_pair(:default_profile, "default_profile")
  end

  defp normalize_config(_config), do: %{}

  defp put_config_pair(config, atom_key, string_key) do
    value = Map.get(config, atom_key, Map.get(config, string_key))

    if is_nil(value) do
      config
    else
      config
      |> Map.put(atom_key, value)
      |> Map.put(string_key, value)
    end
  end
end
