defmodule YellowDog.Dns.Supervisor do
  @moduledoc """
  The main supervisor for the YellowDog DNS application.

  Manages the DNS server with proper supervision strategy following
  the same pattern as DHCPv4/v6 applications.

  The supervisor only starts if DNS is enabled in the YellowDog configuration.
  """

  use Supervisor

  alias YellowDog.Telemetry

  @doc """
  Starts the DNS server supervisor.

  ## Options
  - `name`: Supervisor name (default: YellowDog.Dns)
  - `server_options`: Options passed to DNS server

  ## Returns
  - `{:ok, pid}` - Supervisor started successfully
  - `{:error, reason}` - Failed to start supervisor
  - `:ignore` - DNS service is disabled in configuration
  """
  @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
  def start_link(opts) do
    # Check if DNS service is enabled
    unless apply(YellowDog.Config, :service_enabled?, [:dns]) do
      Telemetry.info("DNS service is disabled, skipping startup")
      :ignore
    else
      opts = Map.new(opts)
      name = Map.get(opts, :name, YellowDog.Dns)
      opts = Map.put(opts, :name, name)

      Telemetry.debug("Starting DNS supervisor")
      Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    Telemetry.span("dns.supervisor.init", %{}, fn ->
      children = build_children(opts)
      Supervisor.init(children, strategy: :one_for_one)
    end)
  end

  defp build_children(opts) do
    server_options = Map.get(opts, :server_options, [])

    [
      # Zone Manager - manages zone lifecycle and storage
      {YellowDog.Dns.Zone.Manager, []}
      |> Supervisor.child_spec(id: :zone_manager, restart: :permanent),

      # DNS Server (wraps Abyss UDP server)
      {YellowDog.Dns.Server, server_options}
      |> Supervisor.child_spec(id: :server, restart: :permanent),

      # Post-start task - load configured zones
      {Task,
       fn ->
         Telemetry.debug("DNS post-start task: loading configured zones")
         # TODO: Load zones from configuration
         # zones = YellowDog.Config.get(:dns, :zones) || []
         # Enum.each(zones, fn zone_config ->
         #   YellowDog.Dns.Zone.Manager.load_zone(zone_config.name, zone_config)
         # end)
         Telemetry.debug("DNS post-start task completed")
       end}
      |> Supervisor.child_spec(id: :post_start, restart: :temporary)
    ]
  end
end
