defmodule YellowDog.ManagementUI.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_root_layout, html: {YellowDog.ManagementUI.Layouts, :root}

    plug :put_secure_browser_headers, %{
      # TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#172
      # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#172
      "content-security-policy" =>
        "default-src 'none'; script-src 'self'; script-src-attr 'unsafe-hashes' 'sha256-NaIeMghFEg+ph81F//6Bd2P0/9dHc/y2X7leoJ7MLmA='; connect-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
    }
  end

  scope "/", YellowDog.ManagementUI do
    pipe_through :browser

    live_session :management,
      on_mount: [{YellowDog.ManagementUI.Hooks.CurrentPath, :default}],
      layout: false do
      live "/", OverviewLive, :overview
      live "/management", OverviewLive, :overview
      live "/management/servers", WorkersLive, :index
      live "/management/netman", NetmansLive, :index
      live "/management/events", EventsLive, :index
      live "/management/config", ConfigLive, :index
      live "/management/profiles", ManagementLive.ProfilesLive, :index
      live "/management/dns/views", DnsViewsLive, :selector
      live "/server", WorkersLive, :index
      live "/server/:server_id/dashboard", WorkerLive, :show
      live "/server/:server_id/dns", WorkerLive, :show
      live "/server/:server_id/dns/acl", DnsAclsLive, :selector
      live "/server/:server_id/dns/acl/:service_id", DnsAclsLive, :index
      live "/server/:server_id/dns/views", DnsViewsLive, :selector
      live "/server/:server_id/dns/views/:service_id", DnsViewsLive, :index
      live "/netman", NetmansLive, :index
      live "/netman/:netman_id", NetmanLive, :show
      live "/netman/:netman_id/config", NetmanConfigLive, :config
      live "/netman/:netman_id/resolved", NetmanConfigLive, :resolved
      live "/management/zones", ZonesLive, :index
      live "/management/zones/new", ZonesLive, :new
      live "/management/zones/import", ZoneImportLive, :import
      live "/management/zones/:zone_id/edit", ZonesLive, :edit
      live "/management/zones/:zone_id/records", RecordsLive, :index
      live "/management/zones/:zone_id/records/new", RecordsLive, :new
      live "/management/zones/:zone_id/records/bulk", RecordsLive, :bulk
      live "/management/zones/:zone_id/records/:rr_index/edit", RecordsLive, :edit
      live "/server/:server_id/dns/zones", ZonesLive, :index
      live "/server/:server_id/dns/zones/new", ZonesLive, :new
      live "/server/:server_id/dns/zones/import", ZoneImportLive, :import
      live "/server/:server_id/dns/zones/:zone_id/edit", ZonesLive, :edit
      live "/server/:server_id/dns/zones/:zone_id/records", RecordsLive, :index
      live "/server/:server_id/dns/zones/:zone_id/records/new", RecordsLive, :new
      live "/server/:server_id/dns/zones/:zone_id/records/bulk", RecordsLive, :bulk
      live "/server/:server_id/dns/zones/:zone_id/records/:rr_index/edit", RecordsLive, :edit
      live "/tool/mac", ToolsLive.MacLive, :index
      live "/tool/whois", ToolsLive.WhoisLive, :index
      live "/tool/geoip", ToolsLive.GeoipLive, :index
      live "/system/logs", LogsLive, :index
      live "/system/logs/realtime", LogsLive, :realtime
      live "/system/logs/tasks", TasksLive, :logs
      live "/system/tasks", TasksLive, :index
      live "/system/tasks/:task", TasksLive, :show
      live "/system/backups", BackupsLive, :index
      live "/system/backups/restore", BackupsLive, :restore
      live "/system/process-map", ProcessMapLive, :index
      live "/system/ip-database", IpDatabaseLive, :index
      live "/system/mac-database", MacDatabaseLive, :index
    end
  end

  forward "/api/worker", YellowDog.Management.WorkerAPI
  forward "/", YellowDog.Management.Web
end
