defmodule YellowDog.Console.Router do
  @moduledoc """
  Phoenix router for the YellowDog web console.

  Defines HTTP routes for all console pages including:
  - Dashboard: Service overview and status monitoring
  - Settings: DNS, mDNS, DHCPv4, DHCPv6 configuration
  - mDNS: Service registration, discovery, and monitoring
  - DHCPv4/v6: Lease management and pool configuration
  - DNS: Zone and resource record management
  - System: Logs, process map, telemetry

  All browser routes use basic authentication when enabled in production.
  """

  use YellowDog.Console, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {YellowDog.Console.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' ws: wss:; font-src 'self'; frame-ancestors 'none'"
    }

    plug YellowDog.Console.Plugs.BasicAuth
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :boot do
    plug :accepts, ["html", "json", "text"]
  end

  scope "/", YellowDog.Console do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Server section — protocol services, identity, fingerprint
  scope "/server", YellowDog.Console do
    pipe_through :browser

    live "/dashboard", DashboardLive

    # DNS
    live "/dns", DnsLive.Index
    live "/dns/views", DnsLive.ViewLive.Index, :index
    live "/dns/views/new", DnsLive.ViewLive.Index, :new
    live "/dns/views/:view_name/edit", DnsLive.ViewLive.Index, :edit
    live "/dns/views/:view_name/zones", DnsLive.ZoneLive.Index, :index
    live "/dns/views/:view_name/zones/new", DnsLive.ZoneLive.Index, :new
    live "/dns/views/:view_name/zones/import", DnsLive.ZoneLive.Index, :import
    live "/dns/views/:view_name/zones/:zone_type/:zone_name/edit", DnsLive.ZoneLive.Index, :edit
    live "/dns/views/:view_name/zones/:zone_type/:zone_name/records", DnsLive.RrLive.Index, :index

    live "/dns/views/:view_name/zones/:zone_type/:zone_name/records/new",
         DnsLive.RrLive.Index,
         :new

    live "/dns/views/:view_name/zones/:zone_type/:zone_name/records/bulk",
         DnsLive.RrLive.Index,
         :bulk

    live "/dns/views/:view_name/zones/:zone_type/:zone_name/records/:rr_index/edit",
         DnsLive.RrLive.Index,
         :edit

    live "/dns/acl", DnsLive.AclLive
    live "/dns/logs", DnsLive.QueryLogsLive
    live "/dns/metrics", DnsLive.MetricsLive

    # DHCPv4
    live "/dhcpv4", Dhcpv4Live.Index
    live "/dhcpv4/leases", Dhcpv4Live.LeasesLive
    live "/dhcpv4/pools", Dhcpv4Live.PoolsLive
    live "/dhcpv4/pools/:pool_name", Dhcpv4Live.PoolLive
    live "/dhcpv4/activity", Dhcpv4Live.ActivityLive

    # DHCPv6
    live "/dhcpv6", Dhcpv6Live.Index
    live "/dhcpv6/leases", Dhcpv6Live.LeasesLive
    live "/dhcpv6/pools", Dhcpv6Live.PoolsLive
    live "/dhcpv6/pools/:pool_name", Dhcpv6Live.PoolLive
    live "/dhcpv6/activity", Dhcpv6Live.ActivityLive

    # mDNS
    live "/mdns", MdnsLive.Index
    live "/mdns/services", MdnsLive.ServicesLive
    live "/mdns/discovery", MdnsLive.DiscoveryLive
    live "/mdns/monitor", MdnsLive.MonitorLive

    # Netboot
    live "/netboot", NetbootLive.Index
    live "/netboot/devices", NetbootLive.DevicesLive
    live "/netboot/devices/:mac", NetbootLive.DeviceDetailLive
    live "/netboot/profiles", NetbootLive.ProfilesLive
    live "/netboot/profiles/new", NetbootLive.ProfileEditorLive
    live "/netboot/profiles/:id/edit", NetbootLive.ProfileEditorLive
    live "/netboot/tftp", NetbootLive.TftpLive
    live "/netboot/log", NetbootLive.LogLive

    # Identity (Host Registry)
    live "/identity", IdentityLive.Index
    live "/identity/hosts", IdentityLive.HostsLive
    live "/identity/hosts/:id", IdentityLive.HostDetailLive
    live "/identity/approvals", IdentityLive.ApprovalsLive
    live "/identity/tokens", IdentityLive.TokensLive
    live "/identity/policies", IdentityLive.PoliciesLive
    live "/identity/audit", IdentityLive.AuditLive
  end

  # Tool section — network utilities
  scope "/tool", YellowDog.Console do
    pipe_through :browser

    live "/geoip", ToolsLive.GeoipLive
    live "/whois", ToolsLive.WhoisLive
    live "/mac", ToolsLive.MacLive

    # Service Diagnostics
    live "/diagnostics", DiagnosticsLive, :dns
    live "/diagnostics/dns", DiagnosticsLive, :dns
    live "/diagnostics/mdns", DiagnosticsLive, :mdns
    live "/diagnostics/dhcpv4", DiagnosticsLive, :dhcpv4
    live "/diagnostics/dhcpv6", DiagnosticsLive, :dhcpv6
  end

  # System section — configuration, diagnostics, logs
  scope "/system", YellowDog.Console do
    pipe_through :browser

    live "/settings", SettingsLive, :dns
    live "/settings/dns", SettingsLive, :dns
    live "/settings/mdns", SettingsLive, :mdns
    live "/settings/dhcpv4", SettingsLive, :dhcpv4
    live "/settings/dhcpv6", SettingsLive, :dhcpv6
    live "/settings/netboot", SettingsLive, :netboot
    live "/logs", LogsLive, :index
    live "/logs/realtime", LogsLive, :realtime
    live "/logs/dns-query", DnsLive.QueryLogsLive
    live "/logs/dhcpv4-activity", Dhcpv4Live.ActivityLive
    live "/logs/dhcpv6-activity", Dhcpv6Live.ActivityLive
    live "/logs/netboot", NetbootLive.LogLive
    live "/logs/identity-audit", IdentityLive.AuditLive
    live "/process-map", ProcessMapLive

    # Fingerprint (provider data)
    live "/fingerprint/devices", FingerprintLive.DevicesLive
    live "/fingerprint/devices/:mac", FingerprintLive.DeviceDetailLive
    live "/fingerprint/fingerprints", FingerprintLive.FingerprintsLive
  end

  # Netman section — central management of remote Netman instances
  scope "/netman", YellowDog.Console do
    pipe_through :browser

    live "/", NetmanLive.DashboardLive
    live "/:node_id", NetmanLive.NodeLive
    live "/:node_id/interfaces", NetmanLive.InterfacesLive
    live "/:node_id/resolved", NetmanLive.ResolvedLive
    live "/:node_id/dhcp-client", NetmanLive.DhcpClientLive
  end

  # HTTP boot endpoints — no CSRF, no session (called by iPXE/installer)
  scope "/boot", YellowDog.Console do
    pipe_through :boot

    get "/ipxe", BootController, :ipxe
    get "/assets/*path", BootController, :asset
    get "/manifest/:device_id", BootController, :manifest
    post "/register", BootController, :register_device
    post "/status", BootController, :status_update
  end

  scope "/api", YellowDog.Console do
    pipe_through :api

    # Host Identity API
    post "/hosts/register", IdentityController, :register
    get "/hosts/recipients", IdentityController, :recipients
    get "/hosts/:id/status", IdentityController, :status
    put "/hosts/:id/approve", IdentityController, :approve
    post "/hosts/:id/revoke", IdentityController, :revoke
    delete "/hosts/:id", IdentityController, :delete
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
