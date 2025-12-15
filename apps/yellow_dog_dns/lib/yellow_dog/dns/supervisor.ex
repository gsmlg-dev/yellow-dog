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

  Note: Service enablement is handled at the application layer.
  This supervisor always starts when invoked.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = Map.new(opts)
    name = Map.get(opts, :name, YellowDog.Dns)
    opts = Map.put(opts, :name, name)

    Telemetry.debug("Starting DNS supervisor")
    Supervisor.start_link(__MODULE__, opts, name: name)
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

    # Get cache configuration from YellowDog.Config
    cache_config =
      case apply(YellowDog.Config, :get, [:dns, :cache]) do
        nil ->
          []

        config when is_map(config) ->
          Enum.into(config, [])

        _ ->
          []
      end

    # Get view configuration
    views_config_path = Application.get_env(:yellow_dog_dns, :views_config_path)
    hot_reload_enabled = get_config(:hot_reload_enabled, false)
    reload_debounce_ms = get_config(:reload_debounce_ms, 300)

    # Build base children list with correct dependency order:
    # Zone.Manager → Cache.Manager → Cache.Cleaner → RootZone.Manager → View.Manager → ConfigWatcher → Server
    base_children = [
      # Zone Manager - manages zone lifecycle and storage
      {YellowDog.Dns.Zone.Manager, []}
      |> Supervisor.child_spec(id: :zone_manager, restart: :permanent),

      # Query Cache Manager - manages DNS query cache
      {YellowDog.Dns.Query.Cache.Manager, cache_config}
      |> Supervisor.child_spec(id: :cache_manager, restart: :permanent),

      # Query Cache Cleaner - periodic cleanup of expired entries
      {YellowDog.Dns.Query.Cache.Cleaner, cache_config}
      |> Supervisor.child_spec(id: :cache_cleaner, restart: :permanent),

      # Root Zone Manager - manages root zone for recursive resolution
      {YellowDog.Dns.RootZone.Manager, strategy: :hints}
      |> Supervisor.child_spec(id: :root_zone_manager, restart: :permanent),

      # View Manager - manages DNS views for split-horizon DNS
      {YellowDog.Dns.View.Manager, [name: YellowDog.Dns.View.Manager]}
      |> Supervisor.child_spec(id: :view_manager, restart: :permanent)
    ]

    # Conditionally add ConfigWatcher if hot-reload is enabled and config path exists
    config_watcher_children =
      if hot_reload_enabled and is_binary(views_config_path) and views_config_path != "" do
        config_watcher_opts = [
          config_path: views_config_path,
          reload_callback: fn views ->
            YellowDog.Dns.View.Manager.update_views(YellowDog.Dns.View.Manager, views)
          end,
          debounce_ms: reload_debounce_ms,
          name: YellowDog.Dns.View.ConfigWatcher
        ]

        [
          {YellowDog.Dns.View.ConfigWatcher, config_watcher_opts}
          |> Supervisor.child_spec(id: :config_watcher, restart: :transient)
        ]
      else
        []
      end

    # Server and post-start task come last
    server_children = [
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

    base_children ++ config_watcher_children ++ server_children
  end

  # Helper to get DNS configuration
  defp get_config(key, default) do
    case apply(YellowDog.Config, :get, [:dns, key]) do
      nil -> default
      value -> value
    end
  rescue
    _ -> default
  end
end
