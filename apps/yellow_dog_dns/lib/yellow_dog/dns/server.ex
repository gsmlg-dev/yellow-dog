defmodule YellowDog.Dns.Server do
  @moduledoc """
  DNS server supervisor using Abyss UDP server library.

  Supervises the DNS subsystem components:
  - SpanManager: Tracks active DNS requests
  - ZoneController: Manages zone processes
  - ViewManager: Manages view processes for split-horizon DNS
  - Abyss: UDP server for receiving DNS packets

  The Handler only does network I/O and delegates resolution to the
  ViewManager, which routes to appropriate View and Zone processes.
  """

  use Supervisor

  alias YellowDog.Telemetry

  @doc """
  Starts the DNS server supervisor.

  ## Options
  - `port`: UDP port to listen on (overrides config)
  - `listen`: IP address to bind to (overrides config)
  - `views`: Initial view configurations
  - `zones`: Initial zone configurations

  ## Returns
  - `{:ok, pid}` - Server started successfully
  - `{:error, reason}` - Failed to start server
  """
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stops the DNS server.
  """
  def stop(pid \\ __MODULE__) do
    Supervisor.stop(pid)
  end

  @doc """
  Gets the default server configuration.
  """
  def get_config do
    %{
      port: 53,
      transport_module: Abyss.Transport.UDP.Unicast,
      handler_module: YellowDog.Dns.Handler.UDP,
      transport_options: [
        ip: {0, 0, 0, 0},
        reuseaddr: true
      ],
      read_timeout: 5_000,
      shutdown_timeout: 5_000,
      num_listeners: 50,
      num_connections: 10_000,
      max_packet_size: 512,
      rate_limit_enabled: true,
      rate_limit_max_packets: 1000,
      rate_limit_window_ms: 1000
    }
  end

  @doc """
  Resolves a DNS query through the server infrastructure.

  This is the main entry point for query resolution from the Handler.
  """
  def resolve(tsi) do
    YellowDog.Dns.ViewManager.resolve(tsi)
  end

  @doc """
  Returns server status and statistics.
  """
  def status do
    %{
      running: Process.whereis(__MODULE__) != nil,
      span_stats: safe_call(&YellowDog.Dns.SpanManager.stats/0, %{}),
      view_stats: safe_call(&YellowDog.Dns.ViewManager.stats/0, %{}),
      zone_stats: safe_call(fn -> length(YellowDog.Dns.ZoneController.list_zones()) end, 0)
    }
  end

  @doc """
  Returns the port the server is listening on.

  This is useful for tests when starting with port 0 (auto-select).
  """
  def get_port(pid \\ __MODULE__) do
    case find_abyss_pid(pid) do
      nil ->
        {:error, :abyss_not_found}

      abyss_pid ->
        case Abyss.Server.listener_pool_pid(abyss_pid) do
          nil ->
            {:error, :no_listener_pool}

          pool_pid ->
            case Abyss.ListenerPool.listener_pids(pool_pid) do
              [] ->
                {:error, :no_listeners}

              [listener_pid | _] ->
                case Abyss.Listener.listener_info(listener_pid) do
                  {_ip, port} when is_integer(port) -> {:ok, port}
                  _ -> {:error, :invalid_listener_info}
                end
            end
        end
    end
  end

  defp find_abyss_pid(supervisor_pid) do
    children = Supervisor.which_children(supervisor_pid)

    Enum.find_value(children, fn
      {:abyss, pid, :supervisor, _} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  # Supervisor callbacks

  @impl true
  def init(opts) do
    Telemetry.info("Starting DNS server supervisor")

    # Build Abyss configuration
    abyss_config = build_server_config(opts)
    port = Keyword.get(abyss_config, :port, 53)
    transport_opts = Keyword.get(abyss_config, :transport_options, [])
    listen_ip = Keyword.get(transport_opts, :ip, {0, 0, 0, 0})

    Telemetry.info("DNS server configuration", %{
      port: port,
      listen: format_ip(listen_ip)
    })

    children = [
      # Registries for named processes
      {Registry, keys: :unique, name: YellowDog.Dns.ZoneRegistry},
      {Registry, keys: :unique, name: YellowDog.Dns.ViewRegistry},
      {Registry, keys: :unique, name: YellowDog.Dns.RecursionRegistry},

      # SpanManager - tracks active TSIs for in-flight requests
      {YellowDog.Dns.SpanManager, name: YellowDog.Dns.SpanManager},

      # ZoneController - supervises zone processes
      {YellowDog.Dns.ZoneController, name: YellowDog.Dns.ZoneController},

      # ViewManager - supervises view processes and routes requests
      {YellowDog.Dns.ViewManager, name: YellowDog.Dns.ViewManager},

      # Post-init task - set up default view and zones
      {Task, fn -> post_init(opts) end},

      # Abyss UDP server - receives DNS packets
      %{
        id: :abyss,
        start: {Abyss, :start_link, [abyss_config]},
        restart: :permanent,
        type: :supervisor
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Private helper functions

  defp post_init(opts) do
    # Wait a bit for processes to start
    Process.sleep(100)

    # Start default view if no views configured
    views = Keyword.get(opts, :views, [])

    if Enum.empty?(views) do
      YellowDog.Dns.ViewManager.start_view(%{
        name: "default",
        acl: :all,
        zones: [],
        recursion_enabled: true
      })
    else
      Enum.each(views, &YellowDog.Dns.ViewManager.start_view/1)
    end

    # Start configured zones
    zones = Keyword.get(opts, :zones, [])
    Enum.each(zones, &start_zone/1)

    # Set up default forwarding zone if not configured
    upstreams = get_upstreams()

    if upstreams != [] do
      YellowDog.Dns.ZoneController.start_zone(:forward, ".", upstreams: upstreams)
    end

    Telemetry.info("DNS server post-init completed")
  end

  defp start_zone(zone_config) do
    type = Map.get(zone_config, :type, :auth)
    name = Map.get(zone_config, :name)
    opts = Map.to_list(zone_config)
    YellowDog.Dns.ZoneController.start_zone(type, name, opts)
  end

  defp get_upstreams do
    case apply(YellowDog.Config, :get, [:dns, :upstream_servers]) do
      nil -> [{{8, 8, 8, 8}, 53}, {{1, 1, 1, 1}, 53}]
      servers when is_list(servers) -> parse_upstreams(servers)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp parse_upstreams(servers) do
    Enum.map(servers, fn
      {ip, port} when is_tuple(ip) -> {ip, port}
      ip when is_tuple(ip) -> {ip, 53}
      ip_str when is_binary(ip_str) -> parse_upstream_string(ip_str)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

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
          {:ok, ip} -> {ip, 53}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp build_server_config(opts) do
    config = get_config()

    port = apply(YellowDog.Config, :get, [:dns, :port]) || config.port
    listen = apply(YellowDog.Config, :get, [:dns, :listen]) || "0.0.0.0"

    listen_ip =
      case parse_ip(listen) do
        {:ok, ip} -> ip
        {:error, _} -> {0, 0, 0, 0}
      end

    config_keywords =
      config
      |> Map.put(:port, port)
      |> Map.update!(:transport_options, fn transport_opts ->
        Keyword.put(transport_opts, :ip, listen_ip)
      end)
      |> Enum.map(fn {key, value} -> {key, value} end)

    {config_keywords, opts_with_transport} =
      case Keyword.get(opts, :listen) do
        nil ->
          {config_keywords, opts}

        listen_opt ->
          case parse_ip(listen_opt) do
            {:ok, ip} ->
              transport_opts = Keyword.get(config_keywords, :transport_options, [])
              updated_transport_opts = Keyword.put(transport_opts, :ip, ip)
              updated_keywords = Keyword.put(config_keywords, :transport_options, updated_transport_opts)
              {updated_keywords, Keyword.delete(opts, :listen)}

            {:error, _} ->
              {config_keywords, Keyword.delete(opts, :listen)}
          end
      end

    config_keywords
    |> Keyword.merge(opts_with_transport)
    |> Keyword.put(:handler_module, YellowDog.Dns.Handler.UDP)
  end

  defp parse_ip(ip_str) when is_binary(ip_str) do
    charlist = String.to_charlist(ip_str)

    case :inet.parse_ipv4_address(charlist) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} ->
        case :inet.parse_ipv6_address(charlist) do
          {:ok, ip} -> {:ok, ip}
          {:error, _} -> {:error, :invalid_ip}
        end
    end
  end

  defp parse_ip(ip) when is_tuple(ip), do: {:ok, ip}
  defp parse_ip(_), do: {:error, :invalid_ip}

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp format_ip({a, b, c, d, e, f, g, h}) do
    parts = [a, b, c, d, e, f, g, h]
    hex_parts = Enum.map(parts, &Integer.to_string(&1, 16))
    Enum.join(hex_parts, ":")
  end

  defp format_ip(other), do: inspect(other)

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end
end
