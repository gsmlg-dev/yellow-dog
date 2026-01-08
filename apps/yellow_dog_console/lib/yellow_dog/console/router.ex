defmodule YellowDog.Console.Router do
  use YellowDog.Console, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {YellowDog.Console.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", YellowDog.Console do
    pipe_through :browser

    get "/", PageController, :home
    live "/dashboard", DashboardLive

    # Settings routes with tab parameter
    live "/settings", SettingsLive, :dns
    live "/settings/dns", SettingsLive, :dns
    live "/settings/mdns", SettingsLive, :mdns
    live "/settings/dhcpv4", SettingsLive, :dhcpv4
    live "/settings/dhcpv6", SettingsLive, :dhcpv6

    # mDNS Management Routes
    live "/mdns", MdnsLive.Index
    live "/mdns/services", MdnsLive.ServicesLive
    live "/mdns/discovery", MdnsLive.DiscoveryLive
    live "/mdns/monitor", MdnsLive.MonitorLive

    # DHCPv4 Management Routes
    live "/dhcpv4", Dhcpv4Live.Index
    live "/dhcpv4/leases", Dhcpv4Live.LeasesLive
    live "/dhcpv4/pools/:pool_name", Dhcpv4Live.PoolLive

    # DHCPv6 Management Routes
    live "/dhcpv6", Dhcpv6Live.Index
    live "/dhcpv6/leases", Dhcpv6Live.LeasesLive
    live "/dhcpv6/pools/:pool_name", Dhcpv6Live.PoolLive

    # DNS Management Routes (sidebar: Overview, Data, ACL)
    live "/dns", DnsLive.Index
    live "/dns/data", DnsLive.DataLive, :views
    live "/dns/data/:view_name", DnsLive.DataLive, :zones
    live "/dns/data/:view_name/:zone_name", DnsLive.DataLive, :records
    live "/dns/acl", DnsLive.AclLive

    # Service Diagnostics
    live "/diagnostics", DiagnosticsLive

    # Real-time Logs
    live "/logs", LogsLive

    # Process Map
    live "/process-map", ProcessMapLive
  end

  scope "/api", YellowDog.Console do
    pipe_through :api
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:yellow_dog_console, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: YellowDog.Console.Telemetry
    end
  end
end
