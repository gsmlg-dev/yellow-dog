defmodule YellowDog.Console.Application do
  @moduledoc """
  The YellowDog Console Application.

  Starts the Phoenix web console for managing and monitoring YellowDog services.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # GeoIP database server (ETS table for IP geolocation lookups)
      GeoIpDb.Database,
      # PubSub for real-time updates
      {Phoenix.PubSub, name: YellowDog.Console.PubSub},
      # Telemetry supervisor for metrics
      YellowDog.Console.Telemetry,
      # Configuration version tracking for settings optimistic locking
      YellowDog.Console.Settings.ConfigurationVersion,
      # Log broadcaster for real-time log streaming to LiveViews
      YellowDog.Console.LogBroadcaster,
      # Rate limiter for authentication attempts (brute-force protection)
      YellowDog.Console.Plugs.AuthRateLimiter,
      # Registry for connected remote Netman service instances
      YellowDog.Console.NetmanRegistry,
      # Note: DHCP LeaseManagers are started by their respective service supervisors
      # (YellowDog.Dhcpv4.Supervisor and YellowDog.Dhcpv6.Supervisor)
      # Do NOT start them here as it causes conflicts when starting services from dashboard
      # Phoenix Endpoint
      YellowDog.Console.Endpoint
    ]

    opts = [strategy: :one_for_one, name: YellowDog.Console.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    YellowDog.Console.Endpoint.config_change(changed, removed)
    :ok
  end
end
