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
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; img-src 'self' data:; connect-src 'self' ws: wss: https://fonts.googleapis.com https://fonts.gstatic.com; font-src 'self' https://fonts.gstatic.com; frame-ancestors 'none'"
    }

    plug YellowDog.Console.Plugs.BasicAuth
    plug YellowDog.Console.Plugs.ManagementReleaseOnly
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug YellowDog.Console.Plugs.ManagementReleaseOnly
  end

  pipeline :management_blob_api do
    plug YellowDog.Console.Plugs.ManagementReleaseOnly
    plug :authenticate_management_token
  end

  pipeline :boot do
    plug :accepts, ["html", "json", "text"]
    plug YellowDog.Console.Plugs.ManagementReleaseOnly
  end

  pipeline :server_scope do
    plug YellowDog.Console.Hooks.ServiceScope, :server
  end

  pipeline :netman_scope do
    plug YellowDog.Console.Hooks.ServiceScope, :netman
  end

  scope "/", YellowDog.Console do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Management section — service-node and Netman management foundation
  scope "/management", YellowDog.Console do
    pipe_through :browser

    live "/", ManagementLive.Index, :overview
    live "/servers", ManagementLive.Index, :servers
    live "/netman", ManagementLive.Index, :netman
    live "/profiles", ManagementLive.Index, :profiles
    live "/config", ManagementLive.Index, :config
    live "/events", ManagementLive.Index, :events
  end

  scope "/management", YellowDog.Console do
    pipe_through :management_blob_api

    get "/blobs/:sha256", ManagementBlobController, :show
  end

  # Server selector — never chooses a default record
  scope "/server", YellowDog.Console do
    pipe_through :browser

    live "/", ServerLive.SelectorLive
    get "/settings/dns", ServiceRedirectController, :server
    get "/settings/mdns", ServiceRedirectController, :server
    get "/settings/dhcpv4", ServiceRedirectController, :server
    get "/settings/dhcpv6", ServiceRedirectController, :server
    get "/settings/netboot", ServiceRedirectController, :server
  end

  # Server section — protocol services, identity, fingerprint
  scope "/server/:server_id", YellowDog.Console do
    pipe_through [:browser, :server_scope]

    live "/dashboard", DashboardLive

    # DNS
    live "/dns", DnsLive.Index
    live "/dns/zones", DnsLive.ZoneLive.Index, :index
    live "/dns/zones/new", DnsLive.ZoneLive.Index, :new
    live "/dns/zones/import", DnsLive.ZoneLive.Index, :import
    live "/dns/zones/:zone_id/edit", DnsLive.ZoneLive.Index, :edit
    live "/dns/zones/:zone_id/records", DnsLive.RrLive.Index, :index
    live "/dns/zones/:zone_id/records/new", DnsLive.RrLive.Index, :new
    live "/dns/zones/:zone_id/records/bulk", DnsLive.RrLive.Index, :bulk
    live "/dns/zones/:zone_id/records/:rr_index/edit", DnsLive.RrLive.Index, :edit
    live "/dns/views", DnsLive.ViewLive.Index, :index
    live "/dns/views/new", DnsLive.ViewLive.Index, :new
    live "/dns/views/:view_name/edit", DnsLive.ViewLive.Index, :edit

    live "/dns/acl", DnsLive.AclLive
    live "/dns/logs", DnsLive.QueryLogsLive
    live "/dns/metrics", DnsLive.MetricsLive

    # DNS Providers
    live "/dns/providers", DnsLive.ProviderLive.Index
    live "/dns/providers/new", DnsLive.ProviderLive.Index, :new
    live "/dns/providers/:name", DnsLive.ProviderLive.Show
    live "/dns/providers/:name/edit", DnsLive.ProviderLive.Show, :edit
    live "/dns/providers/:name/conflicts", DnsLive.ProviderLive.ConflictLive

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

    # Fingerprint (provider data)
    live "/fingerprint/devices", FingerprintLive.DevicesLive
    live "/fingerprint/devices/:mac", FingerprintLive.DeviceDetailLive
    live "/fingerprint/fingerprints", FingerprintLive.FingerprintsLive

    # Legacy cloud-provider entry point backed by the selected Server gateway
    live "/dns/cloud-provider", CloudDnsLive

    # Settings (service configuration)
    live "/settings", SettingsLive, :dns
    live "/settings/dns", SettingsLive, :dns
    live "/settings/mdns", SettingsLive, :mdns
    live "/settings/dhcpv4", SettingsLive, :dhcpv4
    live "/settings/dhcpv6", SettingsLive, :dhcpv6
    live "/settings/netboot", SettingsLive, :netboot
  end

  # Legacy Server service paths — redirect to selection without inferring an ID
  scope "/server", YellowDog.Console do
    pipe_through :browser

    get "/*legacy_path", ServiceRedirectController, :server
  end

  scope "/service-not-found", YellowDog.Console do
    pipe_through :browser

    get "/:service", ServiceRedirectController, :not_found
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

    live "/logs", LogsLive, :index
    live "/logs/realtime", LogsLive, :realtime
    live "/logs/tasks", LogsLive, :tasks
    get "/logs/dns-query", ServiceRedirectController, :server
    get "/logs/dhcpv4-activity", ServiceRedirectController, :server
    get "/logs/dhcpv6-activity", ServiceRedirectController, :server
    get "/logs/netboot", ServiceRedirectController, :server
    get "/logs/identity-audit", ServiceRedirectController, :server
    live "/process-map", ProcessMapLive
    live "/backups", BackupsLive
    live "/backups/restore", BackupsLive, :restore
    get "/backups/download/:filename", BackupController, :download
    live "/tasks", TasksLive.Index
    live "/tasks/:task", TasksLive.Show

    # Fingerprint (provider data)
    get "/provider/cloud-dns", ServiceRedirectController, :server
    get "/fingerprint/devices", ServiceRedirectController, :server
    get "/fingerprint/devices/:mac", ServiceRedirectController, :server
    get "/fingerprint/fingerprints", ServiceRedirectController, :server

    # IP Database management
    live "/ip-database", IpDatabaseLive

    # MAC manufacturer database management
    live "/mac-database", MacDatabaseLive
  end

  # Netman selector and legacy unscoped routes
  scope "/netman", YellowDog.Console do
    pipe_through :browser

    live "/", NetmanLive.DashboardLive
    get "/config", ServiceRedirectController, :netman
  end

  # Netman section — all pages target one concrete management record
  scope "/netman/:netman_id", YellowDog.Console do
    pipe_through [:browser, :netman_scope]

    live "/", NetmanLive.NodeLive
    live "/config", NetmanLive.ConfigLive
    live "/interfaces", NetmanLive.InterfacesLive
    live "/resolved", NetmanLive.ResolvedLive
    live "/dhcp-client", NetmanLive.DhcpClientLive
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

  defp authenticate_management_token(conn, _opts) do
    with ["Bearer " <> provided] <- get_req_header(conn, "authorization"),
         expected when is_binary(expected) and byte_size(expected) > 0 <-
           Application.get_env(:yellow_dog_console, :management_token),
         true <- constant_time_token_match?(provided, expected) do
      conn
    else
      _invalid ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> send_resp(401, "Unauthorized")
        |> halt()
    end
  end

  defp constant_time_token_match?(provided, expected) when is_binary(provided) do
    provided_digest = :crypto.hash(:sha256, provided)
    expected_digest = :crypto.hash(:sha256, expected)
    Plug.Crypto.secure_compare(provided_digest, expected_digest)
  end

  defp constant_time_token_match?(_provided, _expected), do: false
end
