defmodule YellowDog.Dns.Supervisor do
  @moduledoc """
  Top-level supervisor for the DNS subsystem.

  Started by `YellowDog.Dns.Application`, this supervisor manages:
  - `YellowDog.Dns.Server` - Network I/O servers (Abyss UDP + ThousandIsland TCP)
  - `YellowDog.Dns.ZoneController` - Supervises zone processes
  - `YellowDog.Dns.ViewManager` - Manages DNS views and routing
  - `YellowDog.Dns.ConnectionManager` - Manages connection processes for DNS resolution

  ## Process Hierarchy

      YellowDog.Dns.Supervisor
      ├── YellowDog.Dns.Server (Supervisor)
      │   ├── Abyss (UDP Server)
      │   └── ThousandIsland (TCP Server)
      ├── ConnectionManager (DynamicSupervisor)
      │   └── Connection Processes (per-connection)
      ├── ViewManager (Supervisor)
      │   └── View processes (GenServer, one per configured view)
      ├── ZoneController (Supervisor)
      │   └── Zone processes (Auth, Forward, Stub, Root, Cache, RPZ)
      ├── QueryLogger (GenServer) - DNS query/response logging
      ├── MetricsCollector (GenServer) - Telemetry-driven metrics aggregation
      └── ConfigWatcher (GenServer) - Polling-based config hot reload
  """

  use Supervisor

  alias YellowDog.Dns.{ConfigPersistence, IpFormat, View}
  alias YellowDog.Telemetry

  @default_port 53
  @default_listen {0, 0, 0, 0}
  @default_data_path "data/dns"

  @doc """
  Starts the DNS supervisor.

  ## Options
  - `port`: UDP port to listen on (default: 53)
  - `listen`: IP address to bind to (default: "0.0.0.0")
  - `views`: Initial view configurations
  - `zones`: Initial zone configurations

  ## Returns
  - `{:ok, pid}` - Supervisor started successfully
  - `{:error, reason}` - Failed to start supervisor
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    # Register as YellowDog.Dns (not YellowDog.Dns.Supervisor) to match other services
    Supervisor.start_link(__MODULE__, opts, name: YellowDog.Dns)
  end

  @doc """
  Stops the DNS supervisor.
  """
  @spec stop(pid() | atom()) :: :ok
  def stop(pid \\ YellowDog.Dns) do
    Supervisor.stop(pid)
  end

  @doc """
  Returns the status of the DNS subsystem.
  """
  @spec status() :: map()
  def status do
    %{
      running: Process.whereis(YellowDog.Dns) != nil,
      server: safe_call(fn -> YellowDog.Dns.Server.status() end, %{running: false}),
      connection_stats: safe_call(fn -> YellowDog.Dns.ConnectionManager.stats() end, %{}),
      view_stats: safe_call(fn -> YellowDog.Dns.ViewManager.stats() end, %{}),
      zone_count: safe_call(fn -> length(YellowDog.Dns.ZoneController.list_zones()) end, 0)
    }
  end

  # Supervisor callbacks

  @impl true
  def init(opts) do
    Telemetry.info("Starting DNS supervisor")

    # Get server configuration
    port = get_port(opts)
    listen = get_listen(opts)

    # Attach Abyss logger if debug is enabled
    if get_debug(opts) do
      Telemetry.info("Attaching Abyss debug logger")
      Abyss.Logger.attach_logger(:debug)
    end

    Telemetry.info("DNS supervisor configuration", %{
      port: port,
      listen: IpFormat.format(listen)
    })

    children = [
      # Registries for named processes
      {Registry, keys: :unique, name: YellowDog.Dns.ZoneRegistry},
      {Registry, keys: :unique, name: YellowDog.Dns.ViewRegistry},
      {Registry, keys: :unique, name: YellowDog.Dns.ConnectionRegistry},
      {Registry, keys: :unique, name: YellowDog.Dns.RecursionRegistry},

      # Rate limiter - must start before server for DoS protection
      YellowDog.Dns.RateLimiter
      |> Supervisor.child_spec(id: :rate_limiter),

      # AclRegistry - manages named ACL definitions
      {YellowDog.Dns.AclRegistry, acl_file: get_acl_file()},

      # ZoneController - supervises zone processes
      {YellowDog.Dns.ZoneController, name: YellowDog.Dns.ZoneController},

      # ViewManager - supervises view processes and routes requests
      {YellowDog.Dns.ViewManager, name: YellowDog.Dns.ViewManager},

      # ConnectionManager - manages per-connection processes
      {YellowDog.Dns.ConnectionManager, name: YellowDog.Dns.ConnectionManager},

      # Server - network I/O (Abyss UDP + ThousandIsland TCP)
      {YellowDog.Dns.Server, Keyword.merge(opts, port: port, listen: listen)},

      # Observability services
      {YellowDog.Dns.QueryLogger, []},
      {YellowDog.Dns.MetricsCollector, []},
      {YellowDog.Dns.ConfigWatcher, data_path: get_data_path()},

      # Store event consumers — react to Concord state changes
      {YellowDog.Dns.CacheSyncer, []},
      {YellowDog.Dns.ZoneReloader, []},
      {YellowDog.Dns.RpzReloader, []},

      # Post-init task - set up default view and zones
      # Uses restart: :temporary so it doesn't restart after completion
      %{
        id: :post_init,
        start: {Task, :start_link, [fn -> post_init(opts) end]},
        restart: :temporary
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Private helpers

  defp post_init(opts) do
    # Wait for required processes to be ready
    wait_for_process(YellowDog.Dns.ViewManager)
    wait_for_process(YellowDog.Dns.ZoneController)

    # Try to load persisted configuration first (unless skip_persistence is set)
    {persisted_views, persisted_zones} =
      if Keyword.get(opts, :skip_persistence, false) do
        {[], []}
      else
        load_persisted_config()
      end

    # Start views: persisted > opts
    views = Keyword.get(opts, :views, [])

    cond do
      # Use persisted views if available
      persisted_views != [] ->
        Telemetry.info("Loading #{length(persisted_views)} views from persisted config")
        Enum.each(persisted_views, &start_view_from_config/1)

      # Use views from opts if provided
      views != [] ->
        Enum.each(views, &YellowDog.Dns.ViewManager.start_view/1)

      true ->
        :ok
    end

    # Always ensure default view exists as a catch-all fallback
    # Default view has priority :infinity (lowest) so it matches only when no other view does
    ensure_default_view()

    # Start zones: persisted > opts
    zones = Keyword.get(opts, :zones, [])

    if persisted_zones != [] do
      Telemetry.info("Loading #{length(persisted_zones)} zones from persisted config")
      Enum.each(persisted_zones, &start_zone_from_config/1)
    else
      Enum.each(zones, &start_zone/1)
    end

    # Set up default forwarding zone if not configured
    upstreams = get_upstreams()

    if upstreams != [] do
      # Only start if not already started from persisted config
      case YellowDog.Dns.ZoneController.find_zone(:forward, ".") do
        {:ok, _pid} ->
          :ok

        :error ->
          case YellowDog.Dns.ZoneController.start_zone(:forward, ".", upstreams: upstreams) do
            {:ok, _pid} ->
              # Register with default view
              case YellowDog.Dns.ViewManager.get_view("default") do
                {:ok, view_pid} -> View.register_zone(view_pid, :forward, ".")
                :error -> :ok
              end

            {:error, _reason} ->
              :ok
          end
      end
    end

    Telemetry.info("DNS supervisor post-init completed")
  end

  defp load_persisted_config do
    case ConfigPersistence.load_all() do
      {:ok, %{views: views, zones: zones}} ->
        {views, zones}

      {:error, reason} ->
        Telemetry.warning("Failed to load persisted config", %{reason: inspect(reason)})
        {[], []}
    end
  end

  defp start_view_from_config(view_config) do
    # Convert 999999 back to :infinity for default view priority
    priority =
      case view_config[:priority] do
        999_999 -> :infinity
        nil -> 100
        p -> p
      end

    config = %{
      name: view_config.name,
      priority: priority,
      acl: view_config[:match_clients] || view_config[:acl] || :any,
      zones: view_config[:zones] || [],
      rpz_zones: view_config[:rpz_zones] || [],
      recursion_enabled: view_config[:recursion] || false,
      ecs_enabled: view_config[:ecs_enabled] || false
    }

    YellowDog.Dns.ViewManager.start_view(config)
  end

  # Ensures a default view always exists as a catch-all
  defp ensure_default_view do
    case YellowDog.Dns.ViewManager.get_view("default") do
      {:ok, _pid} ->
        # Default view already exists
        :ok

      :error ->
        # Create default view as catch-all
        Telemetry.info("Creating default view as catch-all")

        YellowDog.Dns.ViewManager.start_view(%{
          name: "default",
          priority: :infinity,
          acl: :any,
          zones: [],
          rpz_zones: [],
          recursion_enabled: true,
          ecs_enabled: false
        })
    end
  end

  defp start_zone_from_config(zone_config) do
    type = zone_config.type
    name = zone_config.name
    # Get view_name from config, default to "default" for backward compatibility
    view_name = zone_config[:view_name] || "default"

    opts =
      zone_config
      |> Map.to_list()
      |> Keyword.delete(:name)
      |> Keyword.delete(:type)
      |> Keyword.put(:view_name, view_name)

    # Add zone_data_path for auth zones
    opts =
      if type == :auth do
        zone_file = zone_config[:file]
        data_path = ConfigPersistence.default_data_path()

        opts =
          if zone_file do
            # If file is relative, make it relative to data_path
            full_path =
              if Path.type(zone_file) == :relative do
                Path.join(data_path, zone_file)
              else
                zone_file
              end

            Keyword.put(opts, :zone_file, full_path)
          else
            opts
          end

        case get_zone_data_path() do
          nil -> opts
          path -> Keyword.put_new(opts, :zone_data_path, path)
        end
      else
        opts
      end

    case YellowDog.Dns.ZoneController.start_zone(type, name, opts) do
      {:ok, _pid} ->
        # Register zone with its view so the View's state has proper {type, name} tuples
        # (persisted views only store zone names as strings, not {type, name} tuples)
        case YellowDog.Dns.ViewManager.get_view(view_name) do
          {:ok, view_pid} ->
            View.register_zone(view_pid, type, name)

          :error ->
            Telemetry.warning("View not found for zone registration", %{
              view: view_name,
              zone: name,
              type: type
            })
        end

      {:error, reason} ->
        Telemetry.error("Failed to start zone from config", %{
          name: name,
          type: type,
          view: view_name,
          reason: inspect(reason)
        })
    end
  end

  defp start_zone(zone_config) do
    type = Map.get(zone_config, :type, :auth)
    name = Map.get(zone_config, :name)
    opts = Map.to_list(zone_config)

    # Add zone_data_path for auth zones
    opts =
      if type == :auth do
        case get_zone_data_path() do
          nil -> opts
          path -> Keyword.put(opts, :zone_data_path, path)
        end
      else
        opts
      end

    YellowDog.Dns.ZoneController.start_zone(type, name, opts)
  end

  defp get_data_path do
    ConfigPersistence.default_data_path()
  rescue
    _e in [ArgumentError, UndefinedFunctionError] -> @default_data_path
  end

  defp get_zone_data_path do
    apply(YellowDog.Config, :get, [:dns, :zone_data_path])
  rescue
    _e in [ArgumentError, UndefinedFunctionError] -> nil
  end

  defp get_acl_file do
    case apply(YellowDog.Config, :get, [:dns, :acl_file]) do
      nil ->
        # Default to data directory if zone_data_path is configured
        case get_zone_data_path() do
          nil -> nil
          path -> Path.join(path, "acls.toml")
        end

      file ->
        file
    end
  rescue
    _e in [ArgumentError, UndefinedFunctionError] -> nil
  end

  defp get_port(opts) do
    Keyword.get(opts, :port) ||
      apply(YellowDog.Config, :get, [:dns, :port]) ||
      @default_port
  rescue
    _e in [ArgumentError, UndefinedFunctionError] -> @default_port
  end

  defp get_listen(opts) do
    listen =
      Keyword.get(opts, :listen) ||
        apply(YellowDog.Config, :get, [:dns, :listen]) ||
        "0.0.0.0"

    case parse_ip(listen) do
      {:ok, ip} -> ip
      {:error, _} -> @default_listen
    end
  rescue
    _e in [ArgumentError, UndefinedFunctionError] -> @default_listen
  end

  defp get_debug(opts) do
    case Keyword.get(opts, :debug) do
      nil ->
        case apply(YellowDog.Config, :get, [:dns, :debug]) do
          true -> true
          "true" -> true
          _ -> false
        end

      value when is_boolean(value) ->
        value

      _ ->
        false
    end
  rescue
    _e in [ArgumentError, UndefinedFunctionError] -> false
  end

  defp get_upstreams do
    case apply(YellowDog.Config, :get, [:dns, :upstream_servers]) do
      nil -> [{{8, 8, 8, 8}, @default_port}, {{1, 1, 1, 1}, @default_port}]
      servers when is_list(servers) -> parse_upstreams(servers)
      _ -> []
    end
  rescue
    _e in [ArgumentError, UndefinedFunctionError] -> []
  end

  defp parse_upstreams(servers) do
    for server <- servers,
        parsed = parse_upstream_entry(server),
        parsed != nil,
        do: parsed
  end

  defp parse_upstream_entry({ip, port}) when is_tuple(ip), do: {ip, port}
  defp parse_upstream_entry(ip) when is_tuple(ip), do: {ip, @default_port}
  defp parse_upstream_entry(ip_str) when is_binary(ip_str), do: parse_upstream_string(ip_str)
  defp parse_upstream_entry(_), do: nil

  defp parse_upstream_string(str) do
    case String.split(str, ":") do
      [ip_str, port_str] ->
        with {:ok, ip} <- parse_ip(ip_str),
             {port, ""} <- Integer.parse(port_str) do
          {ip, port}
        else
          _ -> nil
        end

      [ip_str] ->
        case parse_ip(ip_str) do
          {:ok, ip} -> {ip, @default_port}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_ip(ip_str) when is_binary(ip_str) do
    case :inet.parse_address(String.to_charlist(ip_str)) do
      {:ok, _ip} = ok -> ok
      {:error, _} -> {:error, :invalid_ip}
    end
  end

  defp parse_ip(ip) when is_tuple(ip), do: {:ok, ip}
  defp parse_ip(_), do: {:error, :invalid_ip}

  defp safe_call(fun, default) do
    fun.()
  rescue
    _e in [ArgumentError, UndefinedFunctionError, RuntimeError] -> default
  catch
    :exit, _ -> default
  end

  # Waits for a named process to be registered, with timeout
  defp wait_for_process(name, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_process(name, deadline)
  end

  defp do_wait_for_process(name, deadline) do
    case Process.whereis(name) do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_wait_for_process(name, deadline)
        else
          Telemetry.warning("Timeout waiting for process", %{name: name})
          :timeout
        end

      pid when is_pid(pid) ->
        :ok
    end
  end
end
